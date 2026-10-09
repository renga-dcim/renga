defmodule RengaWeb.Browser.HardwareTest do
  @moduledoc """
  A resource's Hardware tab in a real browser: a collapsed run of matching
  slots opens in place, a missing slot's panel records that the part is out
  until a date, and at phone width the comparison stays within the screen
  with 44px slot targets.
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

    templates =
      for bank <- ~w(A B), n <- 1..8 do
        %{
          kind: "memory",
          name: "DIMM #{bank}#{n}",
          position: "#{bank}#{n}",
          attributes: %{"part_number" => "M393A4K40EB3"}
        }
      end

    {server, expected} = assigned_server_fixture(scope, "browser-hardware", templates)

    for bank <- ~w(A B), n <- 1..8, {bank, n} != {"B", 3} do
      actual_component_fixture(scope, server, "memory", "#{bank}#{n}",
        part_number: "M393A4K40EB3"
      )
    end

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

    %{
      conn: conn,
      server: server,
      a1: "slot-template-#{expected["DIMM A1"].component_template_id}",
      b3: "slot-template-#{expected["DIMM B3"].component_template_id}"
    }
  end

  test "a run of matches opens in place and a missing slot records a gap", context do
    context.conn
    |> visit("/inventory/#{context.server.id}/hardware")
    |> assert_has("body .phx-connected")
    |> assert_has("#run-#{context.a1} summary", text: "A1 – B2")
    |> evaluate(visible_js(context.a1), &assert(&1 == false))
    |> click("#run-#{context.a1} summary")
    |> evaluate(visible_js(context.a1), &assert(&1 == true))
    |> click("##{context.b3}")
    |> assert_has("#slot-intents", text: "What happened?")
    |> evaluate(visible_js("slot-panel-container"), &assert(&1 == true))
    |> click_link("#slot-intent-gap", "It is out temporarily")
    |> fill_in("#gap-form input[name='gap[reason]']", "Why is it out?",
      with: "Failed DIMM, RMA open"
    )
    |> click_button("#gap-save", "Accept until then")
    |> assert_has("#flash-info", text: "out until")
    |> assert_has("##{context.b3}", text: "Out until")
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 390, height: 844}
       ]
  test "fits a phone screen with tappable slots", context do
    context.conn
    |> visit("/inventory/#{context.server.id}/hardware")
    |> assert_has("body .phx-connected")
    |> evaluate("document.documentElement.scrollWidth <= window.innerWidth", &assert(&1 == true))
    |> evaluate(heights_js(), fn heights ->
      assert heights != []
      assert Enum.all?(heights, &(round(&1) >= 44))
    end)
    |> click("##{context.b3}")
    |> assert_has("#slot-intents")
    |> evaluate(
      "document.getElementById('slot-panel-container').getBoundingClientRect().width <= window.innerWidth",
      &assert(&1 == true)
    )
  end

  defp visible_js(id), do: "document.getElementById('#{id}').checkVisibility()"

  # Every visible slot target: run summaries and single slots.
  defp heights_js do
    """
    [...document.querySelectorAll('#hardware-comparison summary, #hardware-comparison a[role=row]')]
      .filter(el => el.offsetParent !== null)
      .map(el => el.getBoundingClientRect().height)
    """
  end
end
