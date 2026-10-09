defmodule RengaWeb.CatalogMovesLiveTest do
  @moduledoc """
  Moving resources to a newer revision: one from its Hardware tab, several
  from the type's "Used by" list, and the per-type automatic move switch.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog
  alias Renga.Catalog.Drafts

  setup %{conn: conn} do
    organization = organization_fixture()
    member = scope_for(organization, "member")

    {fits, _} =
      assigned_server_fixture(member, "moves-fits", [
        %{
          kind: "memory",
          name: "DIMM A1",
          position: "A1",
          attributes: %{"part_number" => "M-32G"}
        }
      ])

    hardware_type = Catalog.get_hardware_assignment(member, fits.id).hardware_type
    {:ok, other} = Renga.Inventory.create_resource(member, %{kind: "server", name: "moves-other"})
    {:ok, _} = Catalog.assign_hardware_type(member, other.id, hardware_type.id)

    actual_component_fixture(member, fits, "memory", "A1", part_number: "M-64G")
    actual_component_fixture(member, other, "memory", "A1", part_number: "M-32G")

    # Revision 2 expects 64 GB modules: the first server fits it, the other does not.
    {:ok, draft} = Drafts.start_draft(member, hardware_type)

    {:ok, draft} =
      Drafts.put_template_group(member, draft, Enum.map(draft.component_templates, & &1.id), %{
        "kind" => "memory",
        "name_pattern" => "DIMM A1",
        "attributes" => %{"part_number" => "M-64G"}
      })

    {:ok, _revision} = Drafts.publish_draft(member, draft)

    %{
      conn: log_in(conn, member, organization),
      organization: organization,
      member: member,
      fits: fits,
      other: other,
      hardware_type: hardware_type
    }
  end

  test "a resource's Hardware tab offers the newer revision with what it changes", context do
    {:ok, view, _html} = live(context.conn, ~p"/inventory/#{context.fits}/hardware")

    assert has_element?(view, "#move-offer", "Revision 2 is available")
    assert has_element?(view, "#move-offer-summary", "closes 1 difference")

    render_click(view, "move_revision", %{})

    assert has_element?(view, "#flash-info", "Moved to revision 2")
    refute has_element?(view, "#move-offer")
    assert revision(context, context.fits) == 2
  end

  test "the type's Used by list moves the resources that already fit", context do
    {:ok, view, _html} = live(context.conn, ~p"/catalog/hardware-types/#{context.hardware_type}")

    assert has_element?(view, "#used-by-#{context.fits.id}[data-fits=true]", "Fits revision 2")
    assert has_element?(view, "#used-by-#{context.other.id}[data-fits=false]", "Opens 1")

    view |> element("#select-fitting") |> render_click()

    assert has_element?(view, "#used-by-#{context.fits.id}-select[checked]")
    refute has_element?(view, "#used-by-#{context.other.id}-select[checked]")
    assert has_element?(view, "#bulk-move-preview", "closes 1 difference and opens 0")
    assert has_element?(view, "#move-selected", "Move 1 to revision 2")

    render_click(view, "move_selected", %{})

    assert has_element?(view, "#flash-info", "Moved 1 to revision 2")
    assert has_element?(view, "#used-by-#{context.fits.id}", "On the latest revision")
    assert revision(context, context.fits) == 2
    assert revision(context, context.other) == 1

    view |> element("#used-by-#{context.other.id}-select") |> render_click()
    assert has_element?(view, "#move-selected", "Move 1 to revision 2")
    view |> element("#clear-selection") |> render_click()
    assert has_element?(view, "#move-selected[disabled]")
  end

  test "owners and admins switch automatic moves; others see the setting", context do
    {:ok, view, _html} = live(context.conn, ~p"/catalog/hardware-types/#{context.hardware_type}")
    refute has_element?(view, "#auto-move-toggle")
    assert has_element?(view, "#auto-move-state", "only when someone moves them")

    render_click(view, "toggle_auto_move", %{})
    assert has_element?(view, "#flash-error", "owner or admin")

    admin = scope_for(context.organization, "admin")
    conn = log_in(build_conn(), admin, context.organization)
    {:ok, view, _html} = live(conn, ~p"/catalog/hardware-types/#{context.hardware_type}")

    view |> element("#auto-move-toggle") |> render_click()
    assert has_element?(view, "#auto-move-toggle[aria-checked=true]")
    assert Catalog.get_hardware_type!(admin, context.hardware_type.id).auto_move
  end

  test "viewers see who uses the type but cannot move anything", context do
    viewer = scope_for(context.organization, "viewer")
    conn = log_in(build_conn(), viewer, context.organization)
    {:ok, view, _html} = live(conn, ~p"/catalog/hardware-types/#{context.hardware_type}")

    assert has_element?(view, "#used-by-#{context.fits.id}")
    refute has_element?(view, "#bulk-move")
    refute has_element?(view, "#used-by-#{context.fits.id}-select")

    render_click(view, "toggle_used_by", %{"id" => context.fits.id})
    render_click(view, "move_selected", %{})
    assert revision(context, context.fits) == 1

    {:ok, tab, _html} = live(conn, ~p"/inventory/#{context.fits}/hardware")
    refute has_element?(tab, "#move-revision")
    render_click(tab, "move_revision", %{})
    assert revision(context, context.fits) == 1
  end

  defp revision(context, resource),
    do:
      Catalog.get_hardware_assignment(context.member, resource.id).catalog_type_revision.revision

  defp scope_for(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Renga.Accounts.scope_for_user(user, organization.id)
  end

  defp log_in(conn, scope, organization) do
    conn
    |> log_in_user(scope.user)
    |> put_session(:current_organization_id, organization.id)
  end
end
