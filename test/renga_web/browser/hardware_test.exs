defmodule RengaWeb.Browser.HardwareTest do
  @moduledoc """
  A resource's Hardware tab in a real browser: a collapsed run of matching
  slots opens in place, a missing slot's panel records that the part is out
  until a date, and at phone width (RFD 8, "Phone and tablet") the
  comparison stays within the screen with 44px targets while a part is
  recorded as out temporarily or replaced.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  @moduletag :playwright

  @phone [has_touch: true, is_mobile: true, viewport: %{width: 390, height: 844}]

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

  @tag browser_context_opts: @phone
  test "fits a phone screen with tappable slots and records a part out", context do
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
    |> evaluate(panel_fits_js(), &assert(&1 == true))
    |> evaluate(tap_heights_js("#slot-intents a"), &assert_tappable/1)
    |> click("#slot-intent-gap")
    |> assert_has("#gap-form")
    |> evaluate(panel_fits_js(), &assert(&1 == true))
    |> evaluate(tap_heights_js("#gap-form input, #gap-save"), &assert_tappable/1)
    |> fill_in("#gap-form input[name='gap[reason]']", "Why is it out?",
      with: "Failed DIMM, RMA open"
    )
    |> click_button("#gap-save", "Accept until then")
    |> assert_has("#flash-info", text: "out until")
    |> assert_has("##{context.b3}", text: "Out until")
  end

  @tag browser_context_opts: @phone
  test "records an installed replacement at phone width", context do
    context.conn
    |> visit("/inventory/#{context.server.id}/hardware")
    |> assert_has("body .phx-connected")
    |> click("##{context.b3}")
    |> click("#slot-intent-replacement")
    |> assert_has("#replacement-form")
    |> evaluate(panel_fits_js(), &assert(&1 == true))
    |> evaluate(tap_heights_js("#replacement-form input, #replacement-save"), &assert_tappable/1)
    |> fill_in("#replacement-form input[name='replacement[part_number]']", "Part number",
      with: "M393A4K40EB3"
    )
    |> fill_in("#replacement-form input[name='replacement[serial_number]']", "Serial number",
      with: "S-90210"
    )
    |> click_button("#replacement-save", "Record replacement")
    |> refute_has("#replacement-form")
    |> assert_has("##{context.b3}", text: "Replacement pending")
  end

  defp assert_tappable(heights) do
    assert heights != []
    assert Enum.all?(heights, &(round(&1) >= 44)), "tap targets under 44px: #{inspect(heights)}"
  end

  defp panel_fits_js do
    """
    (() => {
      const box = document.getElementById('slot-panel-container').getBoundingClientRect();
      return box.left >= 0 && box.right <= window.innerWidth + 0.5 &&
        document.documentElement.scrollWidth <= window.innerWidth;
    })()
    """
  end

  defp tap_heights_js(selector) do
    """
    [...document.querySelectorAll(#{Renga.JSON.encode!(selector)})]
      .filter(el => el.offsetParent !== null && el.type !== 'hidden')
      .map(el => el.getBoundingClientRect().height)
    """
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
