defmodule RengaWeb.Browser.InboxPhoneTest do
  @moduledoc """
  The on-call phone task from RFD 8 at 390px: open a finding from the Inbox,
  assign it, snooze it, and accept it as an exception, with the panel on
  screen, no sideways page scroll, and 44px tap targets.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.AccountsFixtures
  import Renga.FindingsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory

  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "member"})
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    admin_scope = Renga.Accounts.scope_for_user(admin, organization.id)

    {:ok, resource} = Inventory.create_resource(admin_scope, %{kind: "server", name: "web-01"})
    drift = component_finding_fixture(resource, "component_drift")

    other =
      component_finding_fixture(resource, "missing_expected_component",
        key: "other",
        message:
          "Expected a 25GbE network adapter in PCIe slot 3 by the hardware template, " <>
            "but the last inventory report from this machine listed none there"
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

    %{conn: conn, user: user, drift: drift, other: other, organization: organization}
  end

  test "reads, assigns, snoozes, and excepts a finding at phone width", context do
    %{drift: drift, other: other, user: user} = context

    context.conn
    |> visit("/inbox")
    |> assert_has("body .phx-connected")
    |> evaluate(message_lines_js(other.id), &assert(&1 == 2))
    |> click("#finding-link-component-#{drift.id}")
    |> assert_has("#finding-panel [role=dialog]", text: "Component drift")
    |> evaluate(fits_screen_js("#finding-panel [role=dialog]"), &assert(&1 == true))
    |> evaluate(tap_heights_js(), fn heights -> assert Enum.all?(heights, &(&1 >= 44)) end)
    |> click("#finding-assign-me")
    |> assert_has("#finding-history", text: "Assigned to #{user.email}")
    |> click("#finding-snooze-1h")
    |> assert_has("#finding-state", text: "Snoozed")
    |> refute_has("#findings-#{drift.id}")
    |> visit("/inbox?finding=component:#{other.id}")
    |> assert_has("#finding-panel [role=dialog]")
    |> fill_in("#finding-exception-form textarea", "Why is this acceptable?",
      with: "Chassis is being replaced"
    )
    |> click_button("Accept as exception")
    |> assert_has("#finding-exception", text: "Chassis is being replaced")
    |> refute_has("#findings-#{other.id}")
  end

  test "owner can scroll deferred evidence and page it with touch-sized controls", context do
    owner = Renga.JobsFixtures.member_scope(context.organization, "owner")
    {:ok, {key, _}} = Inventory.create_intake_api_key(owner, %{name: "Deferred fleet"})
    installation_id = Ecto.UUID.generate()
    {:ok, {agent, _}} = Inventory.record_intake_agent_check_in(owner, key, installation_id)

    for n <- 1..21 do
      params = %{
        "observation_id" => "phone-deferred-#{n}",
        "observed_at" => "2026-10-30T00:00:00Z",
        "resources" => [%{"kind" => "server", "identifiers" => %{"machine_id" => "phone-#{n}"}}]
      }

      {:ok, _} =
        Renga.Inventory.ReconciliationWork.admit(
          owner,
          key,
          installation_id,
          agent.source_id,
          params,
          %{max_units: 100, max_bytes: 1_000_000}
        )

      {:ok, claim} =
        Renga.Inventory.ReconciliationWork.claim_next(organization_id: owner.organization_id)

      {:ok, _} =
        Renga.Inventory.ReconciliationWork.fail(claim, :quota, %{}, backoff_ms: 60_000)
    end

    {[finding], 1} = Renga.Findings.list_findings(owner, domain: "quota")

    conn =
      add_session_cookie(
        context.conn,
        [
          value: %{
            user_token: Renga.Accounts.generate_user_session_token(owner.user),
            current_organization_id: context.organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    conn
    |> visit("/inbox?finding=quota:#{finding.id}")
    |> assert_has("#quota-deferred-next")
    |> evaluate(fits_screen_js("#finding-panel [role=dialog]"), &assert(&1 == true))
    |> evaluate(
      "document.querySelector('#quota-deferred-next').getBoundingClientRect().height",
      &assert(&1 >= 44)
    )
    |> press("#quota-deferred-next", "Shift+Tab")
    |> assert_has("#finding-details pre:focus")
    |> press("#finding-details pre", "PageDown")
    |> evaluate(
      """
      new Promise(resolve => {
        const pre = document.querySelector('#finding-details pre');
        if (pre.scrollTop > 0) return resolve(true);
        pre.addEventListener('scroll', () => resolve(pre.scrollTop > 0), {once: true});
        setTimeout(() => resolve(false), 1000);
      })
      """,
      &assert(&1)
    )
    |> click("#quota-deferred-next")
    |> assert_has("#quota-deferred-pagination", text: "page 2")
    |> refute_has("#quota-deferred-next")
    |> evaluate(
      "document.querySelector('#quota-deferred-previous').getBoundingClientRect().height",
      &assert(&1 >= 44)
    )
    |> click("#quota-deferred-previous")
    |> assert_has("#quota-deferred-pagination", text: "page 1")
  end

  # The dialog stays within the screen and the page never scrolls sideways.
  defp fits_screen_js(selector) do
    """
    (() => {
      const box = document.querySelector('#{selector}').getBoundingClientRect();
      return box.left >= 0 && box.right <= document.documentElement.clientWidth + 0.5 &&
        document.documentElement.scrollWidth <= document.documentElement.clientWidth;
    })()
    """
  end

  # The lines a finding's message takes in its row; a long one wraps instead of ending at the
  # first ~40 characters, and the clamp keeps it to two lines.
  defp message_lines_js(id) do
    """
    (() => {
      const message = document.querySelector('#finding-link-component-#{id} [data-finding-message]');
      return Math.round(message.getBoundingClientRect().height /
        parseFloat(getComputedStyle(message).lineHeight));
    })()
    """
  end

  defp tap_heights_js do
    """
    Array.from(document.querySelectorAll(
      '#finding-assign-me, #finding-assignee, #finding-snooze button, #finding-exception-save'
    )).map((element) => element.getBoundingClientRect().height)
    """
  end
end
