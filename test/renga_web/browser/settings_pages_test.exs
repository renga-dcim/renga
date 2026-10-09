defmodule RengaWeb.Browser.SettingsPagesTest do
  @moduledoc """
  The sign-in and settings pages at phone width, in a real browser: each
  stays within the screen and its buttons keep 44px touch targets.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  @fits "document.documentElement.scrollWidth <= document.documentElement.clientWidth"
  @buttons "[...document.querySelectorAll('main button, main input[type=submit]')].filter(b => b.offsetParent !== null).map(b => b.getBoundingClientRect().height)"

  defp tappable(heights), do: Enum.all?(heights, &(round(&1) >= 44))

  test "sign-in and registration fit a phone", %{conn: conn} do
    for path <- ~w(/users/log-in /users/register) do
      conn
      |> visit(path)
      |> assert_has("body .phx-connected")
      |> evaluate(@fits, &assert(&1 == true))
      |> evaluate(@buttons, &assert(tappable(&1), "#{path}: #{inspect(&1)}"))
    end
  end

  test "settings pages fit a phone", %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})

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

    for path <-
          ~w(/users/settings /organizations /settings/collectors /settings/teams /settings/triage-rules /settings/appearance) do
      conn
      |> visit(path)
      |> assert_has("body .phx-connected")
      |> evaluate(@fits, &assert(&1 == true, "#{path} scrolls sideways"))
    end
  end

  test "collector details remain readable by scrolling and key controls are 44px in both dimensions",
       %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)
    {:ok, {_key, token}} = Renga.Inventory.create_intake_api_key(scope, %{name: "Fleet"})
    {:ok, key} = Renga.Inventory.authenticate_intake_api_key(token)

    {:ok, {agent, _}} =
      Renga.Inventory.record_intake_agent_check_in(
        scope,
        key,
        "67e55044-10b1-426f-9247-bb680e5fe0c8",
        %{capabilities: ["host.inventory"]}
      )

    {:ok, _} =
      Renga.Inventory.create_observation(scope, agent.source_id, %{
        idempotency_key: "phone-details",
        observed_at: ~U[2026-10-09 12:34:00.000Z],
        payload: %{"resources" => []}
      })

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

    conn
    |> visit("/settings/collectors")
    # The collector rows are in the static render; the create button is not
    # wired until the socket connects.
    |> assert_has("body .phx-connected")
    |> assert_has("#collector-#{agent.source_id}", text: "67e55044…e0c8")
    |> assert_has("#collector-#{agent.source_id}", text: "2026-10-09 12:34 UTC")
    |> evaluate(
      "[...document.querySelectorAll('#collector-#{agent.source_id} td')].every(c => getComputedStyle(c).display !== 'none')",
      &assert(&1 == true)
    )
    |> evaluate(
      "(() => { const table = document.querySelector('#collectors').closest('table'); const wrapper = table.parentElement; wrapper.scrollLeft = wrapper.scrollWidth; return table.querySelector('tbody tr:not(#collectors-empty) td:last-child').getBoundingClientRect().right <= wrapper.getBoundingClientRect().right; })()",
      &assert(&1 == true)
    )
    |> evaluate(@fits, &assert(&1 == true))
    |> click_button("#new-intake-key-button", "Create intake key")
    |> assert_has("#new-intake-key-form")
    |> evaluate(
      "(() => { const r = document.getElementById('cancel-intake-key').getBoundingClientRect(); return r.width >= 44 && r.height >= 44; })()",
      &assert(&1 == true)
    )
    |> fill_in("#new-intake-key-form input[name='intake_api_key[name]']", "Key name",
      with: "Phone fleet"
    )
    |> click_button("#create-intake-key-button", "Create key")
    |> assert_has("#copy-intake-key")
    |> evaluate(
      "(() => { const r = document.getElementById('copy-intake-key').getBoundingClientRect(); return r.width >= 44 && r.height >= 44; })()",
      &assert(&1 == true)
    )
  end
end
