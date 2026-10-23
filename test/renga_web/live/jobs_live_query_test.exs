defmodule RengaWeb.JobsLiveQueryTest do
  @moduledoc "The Jobs views withhold query payloads from readers without the permissions."
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Jobs
  alias Renga.Roles

  @packages "query.packages@1"

  setup do
    %{organization: organization, scope: owner, system_scope: system} =
      job_organization_fixture()

    agent = agent_fixture(organization, ["host.inventory", @packages])
    {:ok, _} = Jobs.update_settings(owner, %{allowed_capabilities: [@packages]})

    {:ok, role} =
      Roles.create_role(owner, %{
        "name" => "Sensitive queries",
        "permissions" => ~w(queries.run queries.run_sensitive)
      })

    member = member_scope(organization, "member")
    {:ok, _} = Assignments.assign(owner, member.membership_id, %{"role" => role.id})
    requester = Accounts.scope_for_user(member.user, organization.id)

    {:ok, job} = Jobs.create_job(requester, agent.id, @packages, %{"name" => "openssl"})
    {:ok, [{_job, token}]} = Jobs.lease_jobs(system, agent, [@packages], 1)

    {:ok, _} =
      Jobs.report(system, agent, job.id, token, "succeeded", %{
        "result" => %{
          "packages" => [
            %{
              "name" => "openssl",
              "version" => "3.0.2",
              "architecture" => "amd64",
              "manager" => "dpkg"
            }
          ],
          "truncated" => false
        }
      })

    %{organization: organization, owner: owner, requester: requester, job: job}
  end

  defp conn_for(conn, scope, organization) do
    conn
    |> log_in_user(scope.user)
    |> put_session(:current_organization_id, organization.id)
  end

  test "an owner without the query permissions sees the job, not its result", context do
    conn = conn_for(context.conn, context.owner, context.organization)

    {:ok, view, html} = live(conn, ~p"/activity/jobs/#{context.job}")

    assert has_element?(view, "#job-payload-hidden", "queries.run and queries.run_sensitive")
    assert has_element?(view, "#job-panel-facts", @packages)
    assert html =~ "Result withheld"
    refute html =~ "openssl"
    refute html =~ "1 package"
  end

  test "a holder of both permissions reads the result", context do
    conn = conn_for(context.conn, context.requester, context.organization)

    {:ok, view, html} = live(conn, ~p"/activity/jobs/#{context.job}")

    refute has_element?(view, "#job-payload-hidden")
    assert html =~ "1 package"
  end
end
