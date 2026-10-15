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

    %{conn: conn, module_type: module_type, scope: scope}
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

  test "module revisions open from a side panel", context do
    context.conn
    |> visit("/catalog/module-types/#{context.module_type.id}")
    |> assert_has("body .phx-connected")
    |> click("#new-revision")
    |> assert_has("#new-revision-panel [role=dialog]", text: "Publish a revision")
    |> assert_has("#new-revision-form")
    |> press("#new-revision-panel [role=dialog]", "Escape")
    |> refute_has("#new-revision-panel [role=dialog]")
    |> assert_has("#new-revision:focus")
  end
end
