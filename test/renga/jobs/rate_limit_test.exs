defmodule Renga.Jobs.RateLimitTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Jobs

  test "rate-limits job creation per organization" do
    %{organization: organization, scope: scope} = job_organization_fixture()

    :ok =
      Renga.Limits.set(
        organization,
        [job_creation_rate: 2],
        Renga.DeploymentAudit.operator("test")
      )

    agent = agent_fixture(organization)

    assert {:ok, _job} = Jobs.create_job(scope, agent.id, "inventory.collect@1", %{})
    assert {:ok, _job} = Jobs.create_job(scope, agent.id, "inventory.collect@1", %{})
    assert {:error, :rate_limited} = Jobs.create_job(scope, agent.id, "inventory.collect@1", %{})

    %{organization: other, scope: other_scope} = job_organization_fixture()
    :ok = Renga.Limits.set(other, [job_creation_rate: 2], Renga.DeploymentAudit.operator("test"))
    other_agent = agent_fixture(other)
    assert {:ok, _job} = Jobs.create_job(other_scope, other_agent.id, "inventory.collect@1", %{})
  end
end
