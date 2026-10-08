defmodule RengaWeb.InboxTriageLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Teams
  alias Renga.Triage

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, member} = member(organization, "member")

    {:ok, server} =
      Inventory.create_resource(admin, %{
        kind: "server",
        name: "web-01",
        lifecycle_state: "active"
      })

    %{
      organization: organization,
      admin_conn: admin_conn,
      member_conn: member_conn,
      admin: admin,
      member: member,
      server: server
    }
  end

  test "the Triage group lists what each resource is missing", context do
    {:ok, _vm} = Inventory.create_resource(context.admin, %{kind: "vm", name: "vm-01"})
    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox?group=triage")

    assert has_element?(view, "#inbox-group-triage", "1")
    assert has_element?(view, "#triage-#{context.server.id} [data-missing=placement]")
    assert has_element?(view, "#triage-#{context.server.id} [data-missing=owner]")
    refute has_element?(view, "#triage", "vm-01")

    {:ok, all, _html} = live(context.admin_conn, ~p"/inbox")
    assert has_element?(all, "#inbox-triage-preview #triage-#{context.server.id}")
  end

  test "an admin supplies an owner and a placement until nothing is missing", context do
    {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})
    {:ok, site} = DCIM.create_site(context.admin, %{name: "DC1"}, %{slug: "dc1"})

    {:ok, rack} =
      DCIM.create_rack(context.admin, %{name: "R12"}, %{site_id: site.id, height_units: 42})

    {:ok, view, _html} =
      live(context.admin_conn, ~p"/inbox?#{[group: "triage", triage: context.server.id]}")

    assert has_element?(view, "#triage-panel", "web-01")

    view |> form("#triage-owner-form", team: team.id) |> render_submit()
    refute has_element?(view, "#triage-owner")
    assert Inventory.get_resource!(context.admin, context.server.id).owner_team_id == team.id

    view |> form("#triage-placement-form") |> render_submit()
    assert render(view) =~ "Choose a rack or a site"

    view
    |> form("#triage-placement-form", placement: %{rack_id: rack.id})
    |> render_submit()

    refute has_element?(view, "#triage-placement")

    assert has_element?(
             view,
             "#triage-hardware a[href='/inventory/#{context.server.id}/hardware']"
           )

    assert Triage.missing(context.admin, context.server) == [:hardware_type]

    # Triage set the rack but never a rack unit.
    placement = Renga.Repo.get_by!(Renga.DCIM.CurrentPlacement, resource_id: context.server.id)
    assert {placement.rack_id, placement.position, placement.confirmed} == {rack.id, nil, true}
  end

  test "members see what is missing but owners and admins supply it", context do
    {:ok, _team} = Teams.create_team(context.admin, %{"name" => "Platform"})

    {:ok, view, _html} =
      live(context.member_conn, ~p"/inbox?#{[group: "triage", triage: context.server.id]}")

    refute has_element?(view, "#triage-owner-form")
    refute has_element?(view, "#triage-placement-form")
    assert has_element?(view, "#triage-owner-request a[href='/inventory/#{context.server.id}']")
    assert has_element?(view, "#triage-placement-unavailable")

    assert render_submit(view, "triage_owner", %{"team" => "whatever"}) =~
             "require the owner or admin role"
  end

  test "filters by a missing fact", context do
    {:ok, team} = Teams.create_team(context.admin, %{"name" => "Platform"})

    {:ok, owned} =
      Inventory.create_resource(context.admin, %{
        kind: "server",
        name: "db-01",
        lifecycle_state: "active"
      })

    {:ok, _owned} = Teams.set_owner(context.admin, owned, team.id)

    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox?group=triage&missing=owner")

    assert has_element?(view, "#inbox-missing-owner[aria-current]")
    assert has_element?(view, "#triage-#{context.server.id}")
    refute has_element?(view, "#triage-#{owned.id}")
  end

  test "a foreign resource id in the URL opens nothing", context do
    other = organization_fixture()
    {_conn, other_admin} = member(other, "admin")
    {:ok, foreign} = Inventory.create_resource(other_admin, %{kind: "server", name: "theirs"})

    {:ok, view, _html} =
      live(context.admin_conn, ~p"/inbox?#{[group: "triage", triage: foreign.id]}")

    refute has_element?(view, "#triage-panel")
  end

  defp member(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Renga.Accounts.scope_for_user(user, organization.id)}
  end
end
