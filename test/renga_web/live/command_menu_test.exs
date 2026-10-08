defmodule RengaWeb.CommandMenuTest do
  @moduledoc """
  Page actions in the command menu: available ones run, unavailable ones are
  listed with the reason they cannot run (RFD 8, Actions).
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(admin, organization.id)

    {:ok, server} =
      Inventory.create_resource(scope, %{kind: "server", name: "compute-01", spec: %{}})

    {:ok, vm} = Inventory.create_resource(scope, %{kind: "vm", name: "guest-01", spec: %{}})

    %{organization: organization, admin: admin, server: server, vm: vm}
  end

  defp signed_in(conn, user, organization) do
    conn
    |> log_in_user(user)
    |> put_session(:current_organization_id, organization.id)
  end

  test "lists the resource's actions under its name", %{conn: conn} = context do
    conn = signed_in(conn, context.admin, context.organization)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.server}")

    assert has_element?(view, "#command-actions", "Actions on compute-01")

    assert has_element?(view, "#command-change-lifecycle[phx-click]")
    refute has_element?(view, "#command-change-lifecycle[aria-disabled]")
    assert has_element?(view, "#command-open-hardware[phx-click]")
  end

  test "explains actions the member's role does not allow", %{conn: conn} = context do
    member = user_fixture()
    organization_membership_fixture(member, context.organization, %{role: "member"})
    conn = signed_in(conn, member, context.organization)

    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.server}")

    assert has_element?(view, "#command-change-lifecycle[aria-disabled='true']")
    refute has_element?(view, "#command-change-lifecycle[phx-click]")

    assert has_element?(
             view,
             "#command-change-lifecycle-reason",
             "Requires the owner or admin role"
           )
  end

  test "explains actions that do not apply to this kind of resource", %{conn: conn} = context do
    conn = signed_in(conn, context.admin, context.organization)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{context.vm}")

    assert has_element?(view, "#command-open-hardware[aria-disabled='true']")
    assert has_element?(view, "#command-open-hardware-reason", "this is a vm")
  end

  test "pages without an object offer no actions group", %{conn: conn} = context do
    conn = signed_in(conn, context.admin, context.organization)
    {:ok, view, _html} = live(conn, ~p"/activity")

    refute has_element?(view, "#command-actions")
  end
end
