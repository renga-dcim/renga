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

    %{conn: conn, user: user, drift: drift, other: other}
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
