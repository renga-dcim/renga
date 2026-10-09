defmodule RengaWeb.Browser.CatalogMovesTest do
  @moduledoc """
  Moving resources from a hardware type's "Used by" list in a real browser:
  selecting those that already fit and confirming the move, and at phone
  width the list stays within the screen with tappable controls.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog
  alias Renga.Catalog.Drafts

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    hardware_type =
      catalog_hardware_type_fixture(scope, "MOVE-UI", [
        %{
          kind: "memory",
          name: "DIMM A1",
          position: "A1",
          attributes: %{"part_number" => "M-32G"}
        }
      ])

    servers =
      for {name, part} <- [{"web-01", "M-64G"}, {"web-02", "M-64G"}, {"web-03", "M-32G"}] do
        {:ok, server} = Renga.Inventory.create_resource(scope, %{kind: "server", name: name})
        {:ok, _} = Catalog.assign_hardware_type(scope, server.id, hardware_type.id)
        actual_component_fixture(scope, server, "memory", "A1", part_number: part)
        server
      end

    {:ok, draft} = Drafts.start_draft(scope, hardware_type)

    {:ok, draft} =
      Drafts.put_template_group(scope, draft, Enum.map(draft.component_templates, & &1.id), %{
        "kind" => "memory",
        "name_pattern" => "DIMM A1",
        "attributes" => %{"part_number" => "M-64G"}
      })

    {:ok, _revision} = Drafts.publish_draft(scope, draft)

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

    %{conn: conn, path: "/catalog/hardware-types/#{hardware_type.id}", servers: servers}
  end

  test "selects the resources that already fit and moves them", context do
    [web1, web2, web3] = context.servers

    context.conn
    |> visit(context.path)
    |> assert_has("body .phx-connected")
    |> click_button("#select-fitting", "Select the 2 that already fit")
    |> assert_has("#bulk-move-preview", text: "closes 2 differences and opens 0")
    |> click_button("#move-selected", "Move 2 to revision 2")
    |> click_button("#bulk-move-dialog-confirm", "Move")
    |> assert_has("#flash-info", text: "Moved 2 to revision 2")
    |> assert_has("#used-by-#{web1.id}", text: "On the latest revision")
    |> assert_has("#used-by-#{web2.id}", text: "On the latest revision")
    |> assert_has("#used-by-#{web3.id}", text: "Opens 1")
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "fits a phone screen with tappable controls", context do
    context.conn
    |> visit(context.path)
    |> assert_has("body .phx-connected")
    |> assert_has("#used-by")
    |> evaluate("document.documentElement.scrollWidth <= window.innerWidth", &assert(&1 == true))
    |> evaluate(
      "[...document.querySelectorAll('#bulk-move button, #auto-move-toggle')].map(b => b.getBoundingClientRect().height)",
      fn heights -> assert Enum.all?(heights, &(round(&1) >= 44)) end
    )
  end
end
