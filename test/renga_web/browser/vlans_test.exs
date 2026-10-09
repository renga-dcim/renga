defmodule RengaWeb.Browser.VlansTest do
  @moduledoc """
  The VLAN area in a real browser: one VLAN still shows as a visible tick
  in a 4,094-ID group, and at phone width a VLAN's member states stay in
  view without scrolling the page sideways.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  @moduletag :playwright

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)

    group = vlan_group_fixture(scope, "fabric")
    users = vlan_fixture(scope, group, 4094, "users")
    {leaf, ports} = device_fixture(scope, "switch", "leaf-01", ~w(swp1 swp2))
    desire_vlans(scope, ports["swp1"], "access", users)
    desire_vlans(scope, ports["swp2"], "access", users)
    report_vlans(scope, leaf, group, %{"swp1" => {"access", [{4094, "untagged"}]}})

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

    %{conn: conn, group: group, users: users, swp2: ports["swp2"].id}
  end

  test "the last VLAN remains visibly inside a full-size group's strip", context do
    context.conn
    |> visit("/network/vlans")
    |> assert_has("body .phx-connected")
    |> assert_has("#vlan-group-#{context.group.id}", text: "1 of 4094 IDs")
    |> evaluate(
      """
      Array.from(document.querySelectorAll('#vlan-group-#{context.group.id}-strip [data-range] > span'))
        .map((tick) => {
          const box = tick.getBoundingClientRect(), segment = tick.parentElement.getBoundingClientRect();
          return Math.max(0, Math.min(box.right, segment.right) - Math.max(box.left, segment.left));
        })
      """,
      fn widths ->
        assert [width] = widths
        assert width >= 1
      end
    )
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "member states stay in view on a phone", context do
    context.conn
    |> visit("/network/vlans/#{context.users.id}")
    |> assert_has("body .phx-connected")
    |> evaluate("document.documentElement.scrollWidth <= window.innerWidth", &assert(&1 == true))
    |> evaluate(
      """
      (() => {
        const state = document.querySelector('#member-#{context.swp2} td:first-child span.block')
        const box = state.getBoundingClientRect()
        return state.textContent.trim() + '|' + (box.width > 0 && box.right <= window.innerWidth)
      })()
      """,
      &assert(&1 == "Planned, not observed|true")
    )
  end
end
