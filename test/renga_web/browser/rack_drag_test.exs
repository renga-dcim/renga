defmodule RengaWeb.Browser.RackDragTest do
  @moduledoc """
  Drag-to-place on the rack elevation (RFD 8, "Places"): dragging a device
  from "Can go in this rack" onto a free unit places it there, with the
  units it would cover highlighted while it is over the rack.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TriageFixtures

  alias Renga.DCIM

  @moduletag :playwright
  @moduletag browser_context_opts: [viewport: %{width: 1360, height: 900}]

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, rack} = DCIM.create_rack(scope, %{name: "R12"}, %{site_id: site.id, height_units: 42})
    web = server_fixture(scope, "web-01")

    conn =
      add_session_cookie(
        conn,
        [
          value: %{
            user_token: Renga.Accounts.generate_user_session_token(user),
            current_organization_id: organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    %{conn: conn, rack: rack, scope: scope, web: web}
  end

  test "drags an unplaced device onto a free unit", %{conn: conn} = context do
    conn
    |> visit("/places/racks/#{context.rack.id}")
    |> assert_has("body .phx-connected")
    |> assert_has("#placeable-#{context.web.id}", text: "web-01")
    |> drag("#placeable-#{context.web.id}", to: "#unit-front-30")
    |> assert_has("#rack-face-front-view [id^=block-front-]", text: "web-01")
    |> refute_has("#placeable-#{context.web.id}")

    assert [%{position: 30, height: 1}] =
             DCIM.rack_elevation(context.scope, context.rack.id).front
  end

  test "invalid footprints highlight occupied and free portions on both faces", context do
    %{scope: scope, rack: rack, web: web} = context
    occupied = server_fixture(scope, "occupied")

    {:ok, _} =
      DCIM.put_current_placement(scope, occupied.id, %{
        rack_id: rack.id,
        position: 10,
        height_units: 2,
        face: "full"
      })

    {:ok, manufacturer} =
      Renga.Catalog.create_manufacturer(scope, %{name: "Acme"}, %{slug: "acme"})

    {:ok, hardware} =
      Renga.Catalog.create_hardware_type(scope, %{name: "2U server"}, %{
        manufacturer_id: manufacturer.id,
        model: "2U",
        device_class: "server"
      })

    {:ok, _} = Renga.Catalog.create_hardware_type_revision(scope, hardware, %{height_units: 2})
    {:ok, _} = Renga.Catalog.assign_hardware_type(scope, web.id, hardware.id)

    conn = context.conn |> visit("/places/racks/#{rack.id}") |> assert_has("body .phx-connected")

    for face <- ["front", "rear"], unit <- [11, 12] do
      conn
      |> evaluate(preview_js(web.id, face, unit), fn result ->
        assert result["units"] == [unit - 1, unit]
        assert result["invalid"] == true
        assert result["painted"] == true
      end)
      |> evaluate("""
      (() => {
        const grid = document.querySelector('[data-rack-face="#{face}"]');
        grid.dispatchEvent(new DragEvent('drop', {bubbles: true, clientY: window.previewY, dataTransfer: window.dragData}));
        document.querySelector('[data-drag-resource]').dispatchEvent(new DragEvent('dragend', {bubbles: true}));
      })()
      """)
      |> assert_has("#placeable-#{web.id}")
    end

    assert Enum.all?(DCIM.rack_elevation(scope, rack.id).front, &(&1.resource.id != web.id))
    assert Enum.all?(DCIM.rack_elevation(scope, rack.id).rear, &(&1.resource.id != web.id))
  end

  test "touch-origin dragstart is cancelled even on desktop", context do
    context.conn
    |> visit("/places/racks/#{context.rack.id}")
    |> assert_has("body .phx-connected")
    |> evaluate(
      """
      (() => {
        const item = document.querySelector('[data-drag-resource]');
        item.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, pointerType: 'touch'}));
        const allowed = item.dispatchEvent(new DragEvent('dragstart', {bubbles: true, cancelable: true, dataTransfer: new DataTransfer()}));
        return !allowed && !document.querySelector('[data-dragging]');
      })()
      """,
      &assert(&1)
    )
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "mouse dragging is cancelled at phone width", context do
    context.conn
    |> visit("/places/racks/#{context.rack.id}")
    |> assert_has("body .phx-connected")
    |> evaluate(
      """
      (() => {
        const item = document.querySelector('[data-drag-resource]');
        item.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, pointerType: 'mouse'}));
        const allowed = item.dispatchEvent(new DragEvent('dragstart', {bubbles: true, cancelable: true, dataTransfer: new DataTransfer()}));
        return !allowed && !document.querySelector('[data-dragging]');
      })()
      """,
      &assert(&1)
    )
  end

  defp preview_js(resource_id, face, unit) do
    """
    (() => {
      const item = document.querySelector('[data-drag-resource="#{resource_id}"]');
      item.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, pointerType: 'mouse'}));
      window.dragData = new DataTransfer();
      item.dispatchEvent(new DragEvent('dragstart', {bubbles: true, dataTransfer: window.dragData}));
      const grid = document.querySelector('[data-rack-face="#{face}"]');
      const rect = grid.getBoundingClientRect();
      window.previewY = rect.top + (42 - #{unit} + 0.5) * rect.height / 42;
      grid.dispatchEvent(new DragEvent('dragover', {bubbles: true, cancelable: true, clientY: window.previewY, dataTransfer: window.dragData}));
      const cells = Array.from(grid.querySelectorAll('[data-drop-target]'));
      return {units: cells.map(c => Number(c.dataset.dropUnit)).sort((a,b) => a-b),
        invalid: cells.every(c => c.dataset.dropTarget === 'invalid'),
        painted: cells.every(c => getComputedStyle(c).backgroundColor !== 'rgba(0, 0, 0, 0)')};
    })()
    """
  end
end
