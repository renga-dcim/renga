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
          ~w(/users/settings /organizations /settings/collectors /settings/members /settings/roles /settings/teams /settings/triage-rules /settings/appearance) do
      conn
      |> visit(path)
      |> assert_has("body .phx-connected")
      |> evaluate(@fits, &assert(&1 == true, "#{path} scrolls sideways"))
    end
  end

  test "member role assignments remain usable by touch and keyboard", %{conn: conn} do
    organization = organization_fixture()
    owner = user_fixture()
    member = user_fixture()
    organization_membership_fixture(owner, organization, %{role: "owner"})
    membership = organization_membership_fixture(member, organization, %{role: "viewer"})
    conn = authenticated_conn(conn, owner, organization)

    conn
    |> visit("/settings/members")
    |> assert_has("body .phx-connected")
    |> click_button("#member-#{membership.id}-roles", "Roles")
    |> assert_has("#assign-panel [role=dialog]", text: "No further roles")
    |> evaluate(
      """
      (() => {
        const panel = document.querySelector('#assign-panel [role=dialog]')
        const controls = [...panel.querySelectorAll('button, input, select, textarea')]
          .filter(control => control.offsetParent !== null)
          .map(control => control.getBoundingClientRect().height)

        return {
          focused: panel.contains(document.activeElement),
          fits: panel.scrollWidth <= panel.clientWidth,
          tappable: controls.every(height => Math.round(height) >= 44)
        }
      })()
      """,
      &assert(&1 == %{"focused" => true, "fits" => true, "tappable" => true})
    )
    |> press("#assign-panel [role=dialog]", "Escape")
    |> refute_has("#assign-panel [role=dialog]")
    |> assert_has("#member-#{membership.id}-roles:focus")
    |> click_button("#member-#{membership.id}-roles", "Roles")
    |> click_button("#assign-save", "Give role")
    |> assert_has("#assign-form [role=alert]", text: "choose a role")
    |> select("#assign-form select", "Give role", option: "Admin", exact: false)
    |> fill_in("Reason (optional)", with: "Incident response")
    |> click_button("#assign-save", "Give role")
    |> assert_has("#assign-current", text: "Admin")
    |> assert_has("#assign-current", text: "Incident response")
    |> select("#assign-form select", "Give role", option: "Admin", exact: false)
    |> click_button("#assign-save", "Give role")
    |> assert_has("#flash-error", text: "already hold that role")
    |> click_button("#assign-current button", "Remove")
    |> assert_has("#assign-current", text: "No further roles")
    |> evaluate(@fits, &assert(&1 == true))
  end

  test "connected member management authority expires without a reload", %{conn: conn} do
    organization = organization_fixture()
    owner = user_fixture()
    member = user_fixture()
    organization_membership_fixture(owner, organization, %{role: "owner"})
    membership = organization_membership_fixture(member, organization, %{role: "viewer"})
    owner_scope = Renga.Accounts.scope_for_user(owner, organization.id)

    {:ok, _assignment} =
      Renga.Assignments.assign(owner_scope, membership.id, %{
        "role" => "admin",
        "valid_until" => DateTime.add(Renga.Time.utc_now_ms(), 2, :second)
      })

    conn
    |> authenticated_conn(member, organization)
    |> visit("/settings/members")
    |> assert_has("body .phx-connected")
    |> assert_has("#invite-member")
    |> refute_has("#invite-member", timeout: 5_000)
    |> assert_has("#members-read-only")
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
         viewport: %{width: 1600, height: 900}
       ]
  test "collector job details remain readable when their column is present", %{conn: conn} do
    %{agent: agent, conn: conn, long_capability: long_capability, resource: resource} =
      collector_context(conn)

    conn
    |> visit("/settings/collectors")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "[document.querySelectorAll('#collector-#{agent.source_id} td')[2], document.getElementById('collector-key-#{agent.source_id}').closest('td')].every(cell => getComputedStyle(cell).display !== 'none')",
      &assert(&1 == true)
    )
    |> assert_has(
      "#collector-#{agent.source_id} a[href='/inventory/#{resource.id}']",
      text: resource.display_name
    )
    |> evaluate(
      """
      new Promise(resolve => {
        const wrapper = document.querySelector('#collectors').closest('table').parentElement
        wrapper.style.width = '1040px'
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const cells = document.querySelectorAll('#collector-#{agent.source_id} td')
          resolve({
            fits: wrapper.scrollWidth <= wrapper.clientWidth,
            collector_width: cells[0].clientWidth,
            resource_visible: getComputedStyle(cells[2]).display !== 'none',
            key_visible: getComputedStyle(document.getElementById('collector-key-#{agent.source_id}').closest('td')).display !== 'none'
          })
        }))
      })
      """,
      fn layout ->
        assert layout["fits"] == true
        assert layout["collector_width"] >= 160
        assert layout["resource_visible"] == true
        assert layout["key_visible"] == true
      end
    )
    |> click_button("#collector-jobs-#{agent.source_id}-list-more", "+1")
    |> assert_has("#collector-jobs-#{agent.source_id}-list-list", text: long_capability)
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
    long_capability = String.duplicate("vendor-long-capability-", 8) <> "@1"

    {:ok, {agent, _}} =
      Renga.Inventory.record_intake_agent_check_in(
        scope,
        key,
        "67e55044-10b1-426f-9247-bb680e5fe0c8",
        %{
          capabilities: ["host.inventory", "inventory.collect@1", long_capability]
        }
      )

    {:ok, observation} =
      Renga.Inventory.create_observation(scope, agent.source_id, %{
        idempotency_key: "collector-details",
        observed_at: ~U[2026-10-09 12:34:00.000Z],
        payload: %{"resources" => []}
      })

    {:ok, resource} =
      Renga.Inventory.create_resource(scope, %{
        kind: "server",
        name: "reported-collector-resource",
        display_name: "Reported collector resource",
        lifecycle_state: "active"
      })

    {:ok, identifier} =
      Renga.Inventory.create_resource_identifier(scope, resource.id, %{
        kind: "serial_number",
        value: "COLLECTOR-BROWSER-RESOURCE"
      })

    {:ok, _claim} =
      Renga.Inventory.create_resource_identifier_claim(
        scope,
        agent.source_id,
        observation.id,
        %{
          resource_id: resource.id,
          resource_identifier_id: identifier.id,
          kind: "serial_number",
          value: "COLLECTOR-BROWSER-RESOURCE",
          confidence: 100
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

    %{
      agent: agent,
      conn: conn,
      key: key,
      long_capability: long_capability,
      resource: resource
    }
  end

  defp authenticated_conn(conn, user, organization) do
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
  end
end
