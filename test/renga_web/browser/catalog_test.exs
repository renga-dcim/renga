defmodule RengaWeb.Browser.CatalogTest do
  @moduledoc """
  Catalog authoring in a real browser: identity and revision forms open from
  explicit actions, retain validation feedback, and restore focus on cancel.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog

  @moduletag :playwright

  @tooltip """
  new Promise(resolve => setTimeout(() => {
    const tooltip = document.getElementById("clip-tooltip")
    resolve(tooltip?.matches(":popover-open") ? tooltip.textContent : null)
  }, 600))
  """

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    {:ok, manufacturer} =
      Catalog.create_manufacturer(
        scope,
        %{name: "Panel Vendor", lifecycle_state: "active"},
        %{slug: "panel-vendor", description: "Browser fixture"}
      )

    {:ok, module_type} =
      Catalog.create_module_type(
        scope,
        %{name: "#{manufacturer.id}-module-panel", lifecycle_state: "active"},
        %{
          manufacturer_id: manufacturer.id,
          model: "PANEL-1",
          module_class: "line_card",
          description: "Browser fixture"
        }
      )

    long_part_number = String.duplicate("LONG-PART-NUMBER-", 12)

    {:ok, _revision} =
      Catalog.create_module_type_revision(scope, module_type, %{part_number: long_part_number})

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

    %{conn: conn, long_part_number: long_part_number, module_type: module_type, scope: scope}
  end

  test "manufacturer creation stays open on errors and closes after success", context do
    session =
      context.conn
      |> visit("/catalog/manufacturers")
      |> assert_has("body .phx-connected")
      |> click("#new-manufacturer")
      |> assert_has("#new-manufacturer-panel [role=dialog]", text: "New manufacturer")
      |> press("#new-manufacturer-panel [role=dialog]", "Escape")
      |> refute_has("#new-manufacturer-panel [role=dialog]")
      |> assert_has("#new-manufacturer:focus")
      |> click("#new-manufacturer")
      |> fill_in("#new-manufacturer-form input[name='manufacturer[name]']", "Name",
        with: "Browser Vendor"
      )
      |> fill_in("#new-manufacturer-form input[name='manufacturer[slug]']", "Slug",
        with: "Not a slug!"
      )
      |> click("#create-manufacturer")
      |> assert_has("#flash-error", text: "has invalid format")
      |> assert_has("#new-manufacturer-panel [role=dialog]")
      |> fill_in("#new-manufacturer-form input[name='manufacturer[slug]']", "Slug",
        with: "browser-vendor"
      )
      |> click("#create-manufacturer")
      |> assert_has("#flash-info", text: "Manufacturer created")
      |> refute_has("#new-manufacturer-panel [role=dialog]")

    [created] =
      Enum.filter(Catalog.list_manufacturers(context.scope), &(&1.slug == "browser-vendor"))

    assert_has(session, "#manufacturer-#{created.id}", text: "Browser Vendor")
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "module revisions reveal long part numbers and open from a side panel", context do
    context.conn
    |> visit("/catalog/module-types/#{context.module_type.id}")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "(() => { const el = document.getElementById('revision-1-part-number'); return el.scrollWidth > el.clientWidth })()",
      &assert(&1 == true)
    )
    |> click("#revision-1-part-number")
    |> evaluate(@tooltip, &assert(&1 == context.long_part_number))
    |> click("#new-revision")
    |> assert_has("#new-revision-panel [role=dialog]", text: "Publish a revision")
    |> assert_has("#new-revision-form")
    |> press("#new-revision-panel [role=dialog]", "Escape")
    |> refute_has("#new-revision-panel [role=dialog]")
    |> assert_has("#new-revision:focus")
  end
end
