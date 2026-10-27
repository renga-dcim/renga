defmodule RengaWeb.Browser.DeletionRecoveryTest do
  use PhoenixTest.Playwright.Case, async: true

  import Renga.JobsFixtures

  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  test "pending owners can reach recovery and cancel at narrow touch width", %{conn: conn} do
    %{organization: organization, scope: scope} = job_organization_fixture()

    {:ok, _} =
      Renga.Operators.OrganizationLifecycle.change(
        organization.id,
        "schedule_deletion",
        Renga.DeploymentAudit.operator("browser-test")
      )

    conn
    |> add_session_cookie(
      [value: %{user_token: Renga.Accounts.generate_user_session_token(scope.user)}],
      RengaWeb.Endpoint.session_options()
    )
    |> visit("/organizations")
    |> click("#deletion-recovery-link")
    |> assert_path("/organizations/deletions")
    |> assert_has("#deletion-#{organization.id}")
    |> evaluate(
      """
      (() => {
        const buttons = [...document.querySelectorAll('#deletion-recovery form button')];
        return document.documentElement.scrollWidth <= innerWidth && buttons.length === 2 &&
          buttons.every(button => {
            const box = button.getBoundingClientRect();
            return box.left >= 0 && box.right <= innerWidth && box.height >= 44;
          });
      })()
      """,
      &assert(&1)
    )
    |> click_button("#cancel-deletion-#{organization.id} button", "Cancel deletion")
    |> assert_has("#no-pending-deletions")

    assert Renga.Accounts.get_organization!(organization.id).status == "active"
  end
end
