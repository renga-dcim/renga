defmodule RengaWeb.Browser.PlacesTest do
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, hall} = DCIM.create_location(scope, %{name: "Hall A"}, %{site_id: site.id})

    {:ok, _row} =
      DCIM.create_location(scope, %{name: "Row 1"}, %{site_id: site.id, parent_id: hall.id})

    {:ok, rack} =
      DCIM.create_rack(scope, %{name: "R12"}, %{site_id: site.id, location_id: hall.id})

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

    %{conn: conn, site: site, hall: hall, rack: rack}
  end

  test "modified site and rack clicks preserve the list, ordinary row clicks navigate", context do
    for {path, row, destination} <- [
          {"/places", "#site-#{context.site.id}", "/places/sites/#{context.site.id}"},
          {"/places/racks", "#rack-#{context.rack.id}", "/places/racks/#{context.rack.id}"}
        ] do
      conn = context.conn |> visit(path) |> assert_has("body .phx-connected")

      conn
      |> unwrap(fn %{frame_id: frame_id} ->
        assert {:ok, _} =
                 PlaywrightEx.Frame.click(frame_id,
                   selector: "#{row} td:first-child a",
                   timeout: 2000,
                   modifiers: ["Control"]
                 )
      end)
      |> evaluate(
        "new Promise(resolve => setTimeout(() => resolve(location.pathname), 150))",
        &assert(&1 == path)
      )

      conn |> click("#{row} td:nth-child(2)") |> assert_path(destination)
    end
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "site tree and child locations retain 44px touch targets at both densities", context do
    for {path, selector} <- [
          {"/places/sites/#{context.site.id}", "#site-locations li a"},
          {"/places/locations/#{context.hall.id}", "#location-children li a"}
        ],
        density <- ["comfortable", "compact"] do
      context.conn
      |> visit(path)
      |> assert_has("body .phx-connected")
      |> evaluate("document.documentElement.dataset.density = '#{density}'")
      |> evaluate(
        "Array.from(document.querySelectorAll('#{selector}')).map(e => e.getBoundingClientRect().height)",
        fn heights ->
          assert heights != []
          assert Enum.all?(heights, &(&1 >= 44))
        end
      )
    end
  end
end
