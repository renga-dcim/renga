defmodule RengaWeb.Browser.JobsTest do
  @moduledoc """
  Jobs in a real browser at phone width: the Jobs list keeps one-line rows
  by dropping columns, the job panel and a resource's collection banner fit
  the screen, and their buttons keep 44px touch targets.
  """
  use PhoenixTest.Playwright.Case, async: true

  import Renga.JobsFixtures

  alias Renga.Jobs

  @moduletag :playwright
  @moduletag browser_context_opts: [
               has_touch: true,
               is_mobile: true,
               viewport: %{width: 390, height: 844}
             ]

  @fits "document.documentElement.scrollWidth <= document.documentElement.clientWidth"

  setup %{conn: conn} do
    %{organization: organization, scope: scope} = job_organization_fixture()
    agent = agent_fixture(organization)
    resource = reported_resource_fixture(organization, agent, "compute-with-a-long-hostname-01")

    {:ok, job} =
      Jobs.create_job(scope, agent.id, "inventory.collect@1", %{}, resource_id: resource.id)

    conn =
      add_session_cookie(
        conn,
        [
          value: %{
            user_token: Renga.Accounts.generate_user_session_token(scope.user),
            current_organization_id: organization.id
          }
        ],
        RengaWeb.Endpoint.session_options()
      )

    %{conn: conn, job: job, resource: resource, scope: scope, agent: agent}
  end

  defp heights(selector),
    do:
      "[...document.querySelectorAll('#{selector}')].filter(b => b.offsetParent !== null).map(b => Math.round(b.getBoundingClientRect().height))"

  test "the Jobs list keeps one-line rows and drops columns on a phone", %{conn: conn, job: job} do
    conn
    |> visit("/activity/jobs")
    |> assert_has("body .phx-connected")
    |> assert_has("#job-#{job.id}-state", text: "Waiting for agent")
    |> evaluate(@fits, &assert(&1 == true, "the Jobs list scrolls sideways"))
    |> evaluate(heights("#jobs-list tr"), fn [row | _] = rows ->
      assert Enum.all?(rows, &(&1 == row)), "rows differ in height: #{inspect(rows)}"
    end)
    |> evaluate(
      "[...document.getElementById('jobs-list').closest('table').querySelectorAll('thead th')].filter(th => th.offsetParent !== null).map(th => th.textContent.trim())",
      &assert(&1 == ["Job", "Target", "State"])
    )
  end

  test "an older job keeps loaded rows and focus through both panel close paths", %{
    conn: conn,
    job: oldest,
    scope: scope,
    agent: agent
  } do
    for _ <- 1..50 do
      {:ok, _job} = Jobs.create_job(scope, agent.id, "inventory.collect@1", %{})
    end

    link = "#jobs-#{oldest.id}-link"

    conn
    |> visit("/activity/jobs")
    |> assert_has("body .phx-connected")
    |> assert_has("#jobs-load-older", text: "Load older jobs")
    |> refute_has("#job-#{oldest.id}-state")
    |> PhoenixTest.Playwright.click("#jobs-load-older")
    |> assert_has("#job-#{oldest.id}-state")
    |> refute_has("#jobs-load-older")
    |> evaluate("document.querySelector(#{Jason.encode!(link)}).focus()")
    |> press(":focus", "Enter")
    |> assert_has("#job-panel [role=dialog]")
    |> press("#job-panel [role=dialog]", "Escape")
    |> refute_has("#job-panel [role=dialog]")
    |> assert_has("#job-#{oldest.id}-state")
    |> assert_has("#{link}:focus")
    |> press(":focus", "Enter")
    |> assert_has("#job-panel [role=dialog]")
    |> PhoenixTest.Playwright.click("#job-close")
    |> refute_has("#job-panel [role=dialog]")
    |> assert_has("#job-#{oldest.id}-state")
    |> assert_has("#{link}:focus")
  end

  test "the job panel fits a phone and its buttons are tappable", %{conn: conn, job: job} do
    conn
    |> visit("/activity/jobs/#{job.id}")
    |> assert_has("#job-panel-status[data-state=queued]")
    |> evaluate(@fits, &assert(&1 == true))
    |> evaluate(
      heights("#job-panel button"),
      &assert(Enum.all?(&1, fn h -> h >= 44 end), inspect(&1))
    )
  end

  test "the job panel opens from the keyboard and restores focus when closed", %{
    conn: conn,
    job: job
  } do
    link = "#jobs-#{job.id}-link"

    conn
    |> visit("/activity/jobs")
    |> assert_has("body .phx-connected")
    |> evaluate("document.querySelector(#{Jason.encode!(link)}).focus()")
    |> assert_has("#{link}:focus")
    |> press(":focus", "Enter")
    |> assert_has("#job-panel [role=dialog]")
    |> evaluate(
      "document.querySelector('#job-panel [role=dialog]').contains(document.activeElement)",
      &assert(&1 == true)
    )
    |> press("#job-panel [role=dialog]", "Escape")
    |> refute_has("#job-panel [role=dialog]")
    |> assert_has("#{link}:focus")
  end

  test "a resource's collection banner fits a phone", %{conn: conn, resource: resource} do
    conn
    |> visit("/inventory/#{resource.id}")
    |> assert_has("#collect-notice[data-state=queued]")
    |> assert_has("#collect-now[aria-disabled=true]")
    |> evaluate(@fits, &assert(&1 == true, "the resource page scrolls sideways"))
    |> evaluate(
      heights("#collect-notice button, #collect-notice a, #collect-now"),
      &assert(Enum.all?(&1, fn h -> h >= 44 end), inspect(&1))
    )
  end

  # Bind and Unbind are short words, so their targets need a minimum width
  # as well as height.
  test "a resource's privileged-job binding is tappable on a phone", %{
    conn: conn,
    agent: agent,
    scope: scope
  } do
    bound = target_binding_fixture(scope.organization, agent)

    sizes =
      "[...document.querySelectorAll('#target-binding button')].filter(b => b.offsetParent !== null).map(b => { const r = b.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)] })"

    conn
    |> visit("/inventory/#{bound.resource.id}/sources")
    |> assert_has("body .phx-connected")
    |> assert_has("#target-binding-current")
    |> evaluate(@fits, &assert(&1 == true, "the Sources tab scrolls sideways"))
    |> evaluate(sizes, fn sizes ->
      assert sizes != []
      assert Enum.all?(sizes, fn [w, h] -> w >= 44 and h >= 44 end), inspect(sizes)
    end)
    |> click_button("#revoke-target-binding-button", "Unbind")
    |> assert_has("#revoke-target-binding [role=alertdialog]")
    |> click_button("#revoke-target-binding-confirm", "Unbind")
    |> assert_has("#target-binding-none")
  end
end
