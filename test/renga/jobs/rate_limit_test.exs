defmodule Renga.Jobs.RateLimitTest do
  # Not async: the limit is application configuration.
  use Renga.DataCase, async: false

  import Renga.JobsFixtures

  alias Renga.Jobs

  setup do
    Application.put_env(:renga, Jobs, creation_rate_per_minute: 2)
    on_exit(fn -> Application.delete_env(:renga, Jobs) end)
  end

  test "rate-limits job creation per organization" do
    %{organization: organization, scope: scope} = job_organization_fixture()
    agent = agent_fixture(organization)

    assert {:ok, _job} = Jobs.create_job(scope, agent.id, "inventory.collect@1", %{})
    assert {:ok, _job} = Jobs.create_job(scope, agent.id, "inventory.collect@1", %{})
    assert {:error, :rate_limited} = Jobs.create_job(scope, agent.id, "inventory.collect@1", %{})

    %{organization: other, scope: other_scope} = job_organization_fixture()
    other_agent = agent_fixture(other)
    assert {:ok, _job} = Jobs.create_job(other_scope, other_agent.id, "inventory.collect@1", %{})
  end
end
