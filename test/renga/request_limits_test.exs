defmodule Renga.RequestLimitsTest do
  use Renga.DataCase, async: true
  import Renga.JobsFixtures
  alias Renga.{Limits, RequestLimits}

  test "user and organization limits compose without spending capacity on rejection" do
    %{organization: organization, scope: first} = job_organization_fixture()
    second = member_scope(organization, "member")
    other = job_organization_fixture().scope

    :ok =
      Limits.set(
        organization,
        [http_organization_rate: 3, http_user_rate: 2],
        Renga.DeploymentAudit.operator("test")
      )

    assert :ok = RequestLimits.check(first, :http, 125)
    assert :ok = RequestLimits.check(first, :http, 126)
    assert {:error, 53} = RequestLimits.check(first, :http, 127)
    assert :ok = RequestLimits.check(second, :http, 128)
    assert {:error, 51} = RequestLimits.check(second, :http, 129)
    assert :ok = RequestLimits.check(other, :http, 129)
    assert :ok = RequestLimits.check(first, :live, 129)
    assert :ok = RequestLimits.check(first, :http, 180)

    :ok = Limits.set(organization, [http_user_rate: 0], Renga.DeploymentAudit.operator("test"))
    assert {:error, 59} = RequestLimits.check(first, :http, 181)
  end
end
