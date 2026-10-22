defmodule RengaWeb.Browser.SettingsPagesTest do
  @moduledoc """
  The sign-in and settings pages at phone width, in a real browser: each
  stays within the screen and its buttons keep 44px touch targets.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Phoenix.ConnTest, only: [build_conn: 0, post: 3]
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint RengaWeb.Endpoint
  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  @fits "document.documentElement.scrollWidth <= document.documentElement.clientWidth"
  @buttons "[...document.querySelectorAll('main button, main input[type=submit]')].filter(b => b.offsetParent !== null).map(b => b.getBoundingClientRect().height)"

  @clip_tooltip """
  new Promise(resolve => setTimeout(() => {
    const tooltip = document.getElementById("clip-tooltip")
    resolve(tooltip?.matches(":popover-open") ? tooltip.textContent : null)
  }, 600))
  """

  @power_sources_fit %{
    "one_line" => true,
    "beside_name" => true,
    "inside" => true,
    "label" => "Power sources: 1 of 2 available",
    "name_readable" => true
  }

  @power_sources_open %{"open" => true, "inside" => true, "hint" => true, "status" => true}

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

  # The table drops its installation key column at this width, so pending
  # keys are listed above it, where they can still be compared and approved.
  test "a pending installation key can be approved by touch at phone width", %{conn: conn} do
    %{agent: agent, conn: conn} = collector_context(conn)

    {:ok, pending} =
      Renga.Repo.transaction(fn ->
        Renga.Inventory.InstallationKeys.present!(
          agent,
          %{algorithm: "ed25519", public_key: :crypto.strong_rand_bytes(32)},
          Renga.Time.utc_now_ms()
        )
      end)

    conn
    |> visit("/settings/collectors")
    |> assert_has("body .phx-connected")
    |> evaluate(
      "getComputedStyle(document.getElementById('collector-key-#{agent.source_id}').closest('td')).display",
      &assert(&1 == "none")
    )
    |> assert_has("#pending-key-#{pending.id}")
    |> evaluate(
      "(() => { const r = document.getElementById('pending-key-#{pending.id}-approve').getBoundingClientRect(); return r.width >= 44 && r.height >= 44; })()",
      &assert(&1 == true)
    )
    |> evaluate(@fits, &assert(&1 == true))
    |> click_button("#pending-key-#{pending.id}-approve", "Approve")
    |> assert_has("#approve-key-#{pending.id} [role=alertdialog]", text: pending.fingerprint)
    |> click_button("#approve-key-#{pending.id}-confirm", "Approve key")
    |> refute_has("#pending-installation-keys")
    |> assert_has("#flash-info", text: "Installation key approved")
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

  test "poller target and state remain readable at phone width", %{conn: conn} do
    %{conn: conn, scope: scope, token: token} = collector_context(conn)

    post_report(token, %{
      "scope" => "hypervisor",
      "collector" => %{"id" => "local-libvirt", "kind" => "vm_provider"},
      "hypervisor" => %{
        "id" => "qemu+ssh://root:secret@hv-01/system?token=hidden#private",
        "status" => "unreachable",
        "error" => "Failed with qemu+ssh://root:secret@hv-01/system?token=hidden#private"
      },
      "complete" => true,
      "resources" => []
    })

    [{_stream, [{target, 0}]}] = Renga.Inventory.Collectors.list_stream_targets(scope)

    conn
    |> visit("/settings/collectors")
    |> assert_has("body .phx-connected")
    |> assert_has("#poller-target-#{target.id}", text: "qemu+ssh://hv-01/system")
    |> assert_has("#poller-target-state-#{target.id}", text: "Unreachable")
    |> evaluate(
      """
      (() => {
        const row = document.getElementById('poller-target-#{target.id}')
        const cells = row.querySelectorAll('td')
        const wrapper = row.closest('table').parentElement
        return {
          fits: wrapper.scrollWidth <= wrapper.clientWidth,
          target_width: cells[0].getBoundingClientRect().width,
          state_width: cells[1].getBoundingClientRect().width,
          optional_hidden: [...cells].slice(2).every(cell => getComputedStyle(cell).display === 'none'),
          leaks: ['root:secret', 'token=hidden', '#private'].some(secret => document.documentElement.innerHTML.includes(secret))
        }
      })()
      """,
      fn layout ->
        assert layout["fits"] == true
        assert layout["target_width"] >= 160
        assert layout["state_width"] >= 100
        assert layout["optional_hidden"] == true
        assert layout["leaks"] == false
      end
    )
  end

  @tag browser_context_opts: [
         has_touch: false,
         is_mobile: false,
         viewport: %{width: 1600, height: 900}
       ]
  test "collector job details remain readable when their column is present", %{conn: conn} do
    %{agent: agent, conn: conn, long_capability: long_capability, resource: resource} =
      collector_context(conn)

    put_power_sources(agent)

    conn
    |> visit("/settings/collectors")
    |> assert_has("body .phx-connected")
    |> evaluate(power_sources_layout(agent), &assert(&1 == @power_sources_fit))
    |> click("#collector-power-#{agent.source_id}")
    |> evaluate(power_sources_popover(agent), &assert(&1 == @power_sources_open))
    |> press("#collector-power-#{agent.source_id}", "Escape")
    |> evaluate(
      "document.getElementById('collector-power-#{agent.source_id}-list').matches(':popover-open')",
      &assert(&1 == false)
    )
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
            name_width: document.getElementById('collector-name-#{agent.source_id}').getBoundingClientRect().width,
            resource_visible: getComputedStyle(cells[2]).display !== 'none',
            key_visible: getComputedStyle(document.getElementById('collector-key-#{agent.source_id}').closest('td')).display !== 'none',
            osquery_visible: document.getElementById('collector-osquery-#{agent.source_id}').offsetParent !== null
          })
        }))
      })
      """,
      fn layout ->
        assert layout["fits"] == true
        assert layout["collector_width"] >= 160
        assert layout["name_width"] >= 96
        assert layout["resource_visible"] == true
        assert layout["key_visible"] == true
        assert layout["osquery_visible"] == true
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

  @tag browser_context_opts: [
         has_touch: false,
         is_mobile: false,
         viewport: %{width: 1600, height: 900}
       ]
  test "the telemetry queue shares the delivery queue's line", %{conn: conn} do
    %{agent: agent, conn: conn} = collector_context(conn)

    queue = %{
      "entries" => 3,
      "bytes" => 4_000,
      "oldest_age_seconds" => 180,
      "dropped_for_space" => 4,
      "expired" => 1,
      "rejected" => 0,
      "unreadable" => 0,
      "dropped_earliest_age_seconds" => 2 * 86_400,
      "dropped_latest_age_seconds" => 3 * 3_600
    }

    agent
    |> Ecto.Changeset.change(metadata: Map.put(agent.metadata, "telemetry_queue", queue))
    |> Renga.Repo.update!()

    conn
    |> visit("/settings/collectors")
    |> assert_has("body .phx-connected")
    |> evaluate(
      """
      (() => {
        const telemetry = document.getElementById('collector-telemetry-queue-#{agent.source_id}')
        const queue = document.getElementById('collector-queue-#{agent.source_id}')
        const row = telemetry.closest('tr').getBoundingClientRect()
        const height = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--rg-row-h'))
        return {
          one_line: row.height <= height + 1,
          same_line: Math.abs(telemetry.getBoundingClientRect().top - queue.getBoundingClientRect().top) < 2
        }
      })()
      """,
      &assert(&1 == %{"one_line" => true, "same_line" => true})
    )
    # The clipped cell still reveals why readings were lost, and when.
    |> evaluate(
      "document.getElementById('collector-telemetry-queue-#{agent.source_id}').closest('[data-clip]').focus()"
    )
    |> evaluate(
      @clip_tooltip,
      &assert(&1 =~ "5 dropped since restart (4 to make room, 1 after a day; queued 2d to 3h")
    )
  end

  test "collector power sources stay on the row and open with a tap at phone width", %{
    conn: conn
  } do
    %{agent: agent, conn: conn} = collector_context(conn)
    put_power_sources(agent)

    conn
    |> visit("/settings/collectors")
    |> assert_has("body .phx-connected")
    |> evaluate(@fits, &assert(&1 == true))
    |> evaluate(power_sources_layout(agent), &assert(&1 == @power_sources_fit))
    |> click("#collector-power-#{agent.source_id}")
    |> evaluate(power_sources_popover(agent), &assert(&1 == @power_sources_open))
  end

  test "every accepted power source stays reachable on a short phone screen", %{conn: conn} do
    %{agent: agent, conn: conn} = collector_context(conn)

    # As many sources as the API accepts, with long names and hints.
    sources =
      for index <- 1..32 do
        %{
          "source" => "http://exporter-#{index}.#{String.duplicate("rack", 20)}.example:9100",
          "status" => "unreachable"
        }
      end

    agent
    |> Ecto.Changeset.change(metadata: Map.put(agent.metadata, "power_sources", sources))
    |> Renga.Repo.update!()

    conn
    |> visit("/settings/collectors")
    |> assert_has("body .phx-connected")
    |> click("#collector-power-#{agent.source_id}")
    |> evaluate(
      """
      new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => {
        const popover = document.getElementById('collector-power-#{agent.source_id}-list')
        popover.scrollTop = popover.scrollHeight
        requestAnimationFrame(() => {
          const box = popover.getBoundingClientRect()
          const last = document.getElementById('collector-power-#{agent.source_id}-31').getBoundingClientRect()
          resolve({
            open: popover.matches(':popover-open'),
            inside: box.top >= 0 && box.bottom <= innerHeight && box.left >= 0 && box.right <= innerWidth,
            scrolls: popover.scrollHeight > popover.clientHeight,
            last_visible: last.top >= box.top && last.bottom <= box.bottom + 1
          })
        })
      })))
      """,
      &assert(
        &1 == %{"open" => true, "inside" => true, "scrolls" => true, "last_visible" => true}
      )
    )
  end

  # A source the agent cannot read, so the popover must show what would
  # enable it.
  defp put_power_sources(agent) do
    agent
    |> Ecto.Changeset.change(
      metadata:
        Map.put(agent.metadata, "power_sources", [
          %{"source" => "power_poller/rack-pdus", "status" => "available"},
          %{"source" => "hwmon", "status" => "not_present"}
        ])
    )
    |> Renga.Repo.update!()
  end

  # The summary sits on the collector's line, so the row keeps its single-line
  # height (or the 44px touch minimum).
  defp power_sources_layout(agent) do
    """
    (() => {
      const button = document.getElementById('collector-power-#{agent.source_id}')
      const name = document.getElementById('collector-name-#{agent.source_id}')
      const row = button.closest('tr').getBoundingClientRect()
      const cell = button.closest('td').getBoundingClientRect()
      const b = button.getBoundingClientRect()
      const n = name.getBoundingClientRect()
      const root = getComputedStyle(document.documentElement)
      const height = Math.max(
        parseFloat(root.getPropertyValue('--rg-row-h')),
        parseFloat(root.getPropertyValue('--rg-tap-min')) || 0
      )
      return {
        one_line: row.height <= height + 1,
        beside_name: Math.abs((b.top + b.bottom) / 2 - (n.top + n.bottom) / 2) < 2,
        inside: button.checkVisibility() && b.left >= cell.left && b.right <= cell.right,
        label: button.getAttribute('aria-label'),
        // The count leaves the collector's name most of the cell.
        name_readable: n.width >= 96 && n.width >= b.width * 2
      }
    })()
    """
  end

  defp power_sources_popover(agent) do
    """
    new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => {
      const popover = document.getElementById('collector-power-#{agent.source_id}-list')
      const box = popover.getBoundingClientRect()
      const hwmon = document.getElementById('collector-power-#{agent.source_id}-1')
      resolve({
        open: popover.matches(':popover-open'),
        inside: box.left >= 0 && box.right <= innerWidth && box.bottom <= innerHeight,
        hint: hwmon.checkVisibility() && hwmon.textContent.includes('ipmi_exporter'),
        status: hwmon.textContent.includes('Not present')
      })
    })))
    """
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
          capabilities: ["host.inventory", "inventory.collect@1", long_capability],
          metadata: %{
            "query_backends" => %{"osquery" => %{"status" => "available", "version" => "5.12.1"}}
          }
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
      resource: resource,
      scope: scope,
      token: token
    }
  end

  defp post_report(token, payload) do
    payload =
      Map.merge(
        %{
          "observation_id" => "poll-#{System.unique_integer([:positive])}",
          "observed_at" => DateTime.to_iso8601(Renga.Time.utc_now_ms())
        },
        payload
      )

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-renga-installation-id", "67e55044-10b1-426f-9247-bb680e5fe0c8")
      |> post("/api/v1/observations", payload)

    assert response.status == 202
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
