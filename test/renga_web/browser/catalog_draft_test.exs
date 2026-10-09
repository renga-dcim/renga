defmodule RengaWeb.Browser.CatalogDraftTest do
  @moduledoc """
  The hardware type draft editor in a real browser: typing a name pattern
  previews the templates it makes before saving, and at phone width the
  editor and its panels stay within the screen with tappable row controls.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    hardware_type =
      catalog_hardware_type_fixture(scope, "R760", [
        %{kind: "memory", name: "DIMM A1", position: "A1", attributes: %{"size_gb" => 64}}
      ])

    {:ok, _draft} = Renga.Catalog.Drafts.start_draft(scope, hardware_type)

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

    %{conn: conn, path: "/catalog/hardware-types/#{hardware_type.id}/draft"}
  end

  test "a name pattern previews its templates before saving", context do
    context.conn
    |> visit(context.path)
    |> assert_has("body .phx-connected")
    |> click_link("#add-template-group", "Add templates")
    |> assert_has("#group-form")
    |> fill_in("#group_name_pattern", "Names", with: "DIMM {A,B}{1..8}")
    |> assert_has("#group-preview", text: "16 templates: DIMM A1, DIMM A2, … DIMM B8")
    |> click_button("#group-save", "Save to draft")
    |> assert_has("#group-form", text: "already a template")
    |> fill_in("#group_name_pattern", "Names", with: "DIMM {A,B}{2..8}")
    |> click_button("#group-save", "Save to draft")
    |> assert_has("#draft-templates", text: "DIMM {A,B}{2..8}")
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "fits a phone screen with tappable row controls", context do
    context.conn
    |> visit(context.path)
    |> assert_has("body .phx-connected")
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> click_button("#add-spec-row", "Add specification")
    |> assert_has("#specs-row-0-remove")
    |> evaluate(
      "document.getElementById('specs-row-0-remove').getBoundingClientRect().height",
      &assert(round(&1) >= 44)
    )
    |> evaluate(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
    |> click_link("#draft-review", "Review and publish")
    |> assert_has("#review-changes")
    |> evaluate(
      "document.getElementById('review-panel-container').getBoundingClientRect().width <= document.documentElement.clientWidth",
      &assert(&1 == true)
    )
  end
end
