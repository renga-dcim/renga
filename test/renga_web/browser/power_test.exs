defmodule RengaWeb.Browser.PowerTest do
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})

    {:ok, feed} =
      Power.create_feed(scope, panel.id, %{
        name: "A1",
        supply: "ac",
        phase: "single",
        voltage: "230",
        amperage: "16"
      })

    {server, _expected} =
      assigned_server_fixture(scope, "web-1", [
        %{kind: "power_port", name: "PSU1", attributes: %{"allocated_draw_w" => 350}}
      ])

    %{ports: [port]} = Power.list_device_endpoints(scope, server.id)

    conn =
      add_session_cookie(
        conn,
        [
          value: %{
            user_token: Accounts.generate_user_session_token(user),
            current_organization_id: organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    %{conn: conn, site: site, feed: feed, server: server, port: port}
  end

  test "a feed editor opens from the keyboard and restores focus when closed", context do
    edit = "#feed-#{context.feed.id}-edit"

    context.conn
    |> visit("/places/sites/#{context.site.id}/power")
    |> assert_has("body .phx-connected")
    |> evaluate("document.querySelector(#{Jason.encode!(edit)}).focus()")
    |> assert_has("#{edit}:focus")
    |> press(":focus", "Enter")
    |> assert_has("#feed-panel [role=dialog]", text: "Edit A1")
    |> evaluate(
      "document.querySelector('#feed-panel [role=dialog]').contains(document.activeElement)",
      &assert(&1 == true)
    )
    |> press("#feed-panel [role=dialog]", "Escape")
    |> refute_has("#feed-panel [role=dialog]")
    |> assert_has("#{edit}:focus")
  end

  test "an allocation editor opens from the keyboard and restores focus when closed", context do
    edit = "#power-port-#{context.port.id}-edit"

    context.conn
    |> visit("/inventory/#{context.server.id}/power")
    |> assert_has("body .phx-connected")
    |> evaluate("document.querySelector(#{Jason.encode!(edit)}).focus()")
    |> assert_has("#{edit}:focus")
    |> press(":focus", "Enter")
    |> assert_has("#allocation-panel [role=dialog]", text: "Allocate PSU1")
    |> evaluate(
      "document.querySelector('#allocation-panel [role=dialog]').contains(document.activeElement)",
      &assert(&1 == true)
    )
    |> press("#allocation-panel [role=dialog]", "Escape")
    |> refute_has("#allocation-panel [role=dialog]")
    |> assert_has("#{edit}:focus")
  end
end
