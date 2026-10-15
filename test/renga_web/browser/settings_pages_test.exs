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

  test "sign-in branding is visible, tappable, and contained at phone width", %{conn: conn} do
    conn
    |> visit("/users/log-in")
    |> assert_has("body .phx-connected")
    |> evaluate(
      """
      (() => {
        const link = document.querySelector("header a[aria-label='Renga home']")
        const wordmark = link.querySelector("svg")
        const tile = document.querySelector("#login > div:first-child svg")
        const linkBox = link.getBoundingClientRect()
        const wordmarkBox = wordmark.getBoundingClientRect()
        const tileBox = tile.getBoundingClientRect()
        const inside = box => box.left >= 0 && box.right <= document.documentElement.clientWidth

        return {
          link_height: linkBox.height,
          wordmark_height: wordmarkBox.height,
          tile_width: tileBox.width,
          tile_height: tileBox.height,
          visible: link.checkVisibility() && wordmark.checkVisibility() && tile.checkVisibility(),
          inside: [linkBox, wordmarkBox, tileBox].every(inside),
          fits: document.documentElement.scrollWidth <= document.documentElement.clientWidth
        }
      })()
      """,
      fn rendering ->
        assert round(rendering["link_height"]) >= 44
        assert_in_delta rendering["wordmark_height"], 24, 0.1
        assert_in_delta rendering["tile_width"], 48, 0.1
        assert_in_delta rendering["tile_height"], 48, 0.1
        assert rendering["visible"] == true
        assert rendering["inside"] == true
        assert rendering["fits"] == true
      end
    )
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

  test "collectors fit the screen without scrolling and key controls are 44px in both dimensions",
       %{conn: conn} do
    %{agent: agent, conn: conn, key: key} = collector_context(conn)

    conn
    |> visit("/settings/collectors")
    # The collector rows are in the static render; the create button is not
    # wired until the socket connects.
    |> assert_has("body .phx-connected")
    |> assert_has("#collector-#{agent.source_id}", text: "Connected")
    # At phone width the table drops its detail columns instead of scrolling
    # (docs/design-system.md, "Overflow"); the name and connection stay.
    |> evaluate(
      "[...document.querySelectorAll('#collector-#{agent.source_id} td')].slice(0, 2).every(c => getComputedStyle(c).display !== 'none')",
      &assert(&1 == true)
    )
    |> evaluate(
      "(() => { const wrapper = document.querySelector('#collectors').closest('table').parentElement; return wrapper.scrollWidth <= wrapper.clientWidth; })()",
      &assert(&1 == true)
    )
    |> evaluate(@fits, &assert(&1 == true))
    |> click_button("#revoke-intake-key-#{key.id}", "Revoke")
    |> assert_has("#revoke-intake-key-#{key.id}-dialog [role=alertdialog]")
    |> click_button("#revoke-intake-key-#{key.id}-dialog-cancel", "Cancel")
    |> refute_has("#revoke-intake-key-#{key.id}-dialog [role=alertdialog]")
    |> click_button("#new-intake-key-button", "Create intake key")
    |> assert_has("#new-intake-key-panel [role=dialog]", text: "Create an intake API key")
    |> press("#new-intake-key-panel [role=dialog]", "Escape")
    |> refute_has("#new-intake-key-panel [role=dialog]")
    |> assert_has("#new-intake-key-button:focus")
    |> click_button("#new-intake-key-button", "Create intake key")
    |> assert_has("#new-intake-key-form")
    |> fill_in("#new-intake-key-form input[name='intake_api_key[name]']", "Key name",
      with: "Phone fleet"
    )
    |> click_button("#create-intake-key-button", "Create key")
    |> assert_has("#new-intake-key-panel [role=dialog]")
    |> assert_has("#intake-key-credentials", text: "Intake key created")
    |> assert_has("#copy-intake-key")
    |> evaluate(
      "(() => { const r = document.getElementById('copy-intake-key').getBoundingClientRect(); return r.width >= 44 && r.height >= 44; })()",
      &assert(&1 == true)
    )
    |> click_button("#finish-intake-key-setup", "I saved this key")
    |> refute_has("#new-intake-key-panel [role=dialog]")
    |> assert_has("#new-intake-key-button:focus")
  end

  @tag browser_context_opts: [
         has_touch: false,
         is_mobile: false,
         viewport: %{width: 1280, height: 800}
       ]
  test "collector job details remain readable when their column is present", %{conn: conn} do
    %{agent: agent, conn: conn} = collector_context(conn)

    conn
    |> visit("/settings/collectors")
    |> assert_has("body .phx-connected")
    |> click_button("#collector-jobs-#{agent.source_id}-list-more", "+1")
    |> evaluate(
      """
      (() => {
        const popover = document.getElementById('collector-jobs-#{agent.source_id}-list-list')
        return {
          open: popover.matches(':popover-open'),
          white_space: getComputedStyle(popover).whiteSpace,
          fits: popover.scrollWidth <= popover.clientWidth
        }
      })()
      """,
      &assert(&1 == %{"open" => true, "white_space" => "normal", "fits" => true})
    )
  end

  defp collector_context(conn) do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)
    {:ok, {_created_key, token}} = Renga.Inventory.create_intake_api_key(scope, %{name: "Fleet"})
    {:ok, key} = Renga.Inventory.authenticate_intake_api_key(token)

    {:ok, {agent, _}} =
      Renga.Inventory.record_intake_agent_check_in(
        scope,
        key,
        "67e55044-10b1-426f-9247-bb680e5fe0c8",
        %{
          capabilities: ["host.inventory", "inventory.collect@1", "query.disk_usage@1"]
        }
      )

    {:ok, _} =
      Renga.Inventory.create_observation(scope, agent.source_id, %{
        idempotency_key: "collector-details",
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

    %{agent: agent, conn: conn, key: key}
  end
end
