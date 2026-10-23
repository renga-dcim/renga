defmodule Renga.Jobs.QueryAccessTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Assignments
  alias Renga.Jobs
  alias Renga.Roles

  @collect "inventory.collect@1"
  @disk "query.disk_usage@1"
  @packages "query.packages@1"

  setup do
    %{organization: organization, scope: owner} = job_organization_fixture()
    agent = agent_fixture(organization, ["host.inventory", @collect, @disk, @packages])

    %{
      organization: organization,
      owner: owner,
      admin: member_scope(organization, "admin"),
      member: member_scope(organization, "member"),
      agent: agent
    }
  end

  defp enable(owner, keys) do
    {:ok, settings} =
      Jobs.update_settings(owner, %{
        allowed_capabilities: Jobs.get_settings(owner.organization).allowed_capabilities ++ keys
      })

    settings
  end

  # Issues explicit permissions the way RFD 17 bootstraps them: an owner
  # defines a role carrying only them and assigns it.
  defp grant(owner, scope, permissions) do
    {:ok, role} =
      Roles.create_role(owner, %{
        "name" => "Queries #{System.unique_integer([:positive])}",
        "permissions" => permissions
      })

    {:ok, assignment} = Assignments.assign(owner, scope.membership_id, %{"role" => role.id})
    assignment
  end

  test "queries are off until the organization enables each one", context do
    grant(context.owner, context.owner, ~w(queries.run))

    refute @disk in Jobs.get_settings(context.organization).allowed_capabilities

    assert {:error, :capability_not_allowed} =
             Jobs.create_job(context.owner, context.agent.id, @disk, %{})

    enable(context.owner, [@disk])
    assert {:ok, job} = Jobs.create_job(context.owner, context.agent.id, @disk, %{})
    assert job.risk_class == "observe"
    assert job.timeout_ms == 30_000
    # Enabling one query enables no other.
    refute @packages in Jobs.get_settings(context.organization).allowed_capabilities
  end

  test "the system never runs a query on its own behalf", context do
    enable(context.owner, [@disk, @packages])

    for key <- [@disk, @packages] do
      assert {:error, :forbidden} =
               Jobs.create_system_job(context.organization.id, context.agent.id, key, %{})
    end

    assert {:ok, _job} =
             Jobs.create_system_job(context.organization.id, context.agent.id, @collect, %{})
  end

  test "Activity never records an agent's reason for a failed query", context do
    enable(context.owner, [@packages])
    grant(context.owner, context.owner, ~w(queries.run queries.run_sensitive))
    resource = reported_resource_fixture(context.organization, context.agent)
    system = Renga.Accounts.scope_for(context.organization)

    {:ok, job} =
      Jobs.create_job(context.owner, context.agent.id, @packages, %{"name" => "ssl"},
        resource_id: resource.id
      )

    {:ok, [{_job, token}]} = Jobs.lease_jobs(system, context.agent, [@packages], 1)
    {:ok, _} = Jobs.report(system, context.agent, job.id, token, "started", %{})

    {:ok, _} =
      Jobs.report(system, context.agent, job.id, token, "failed", %{
        "reason" => "rpmdb open failed"
      })

    outcome =
      context.owner |> Renga.Inventory.list_activity() |> Enum.find(&(&1.kind == "job_outcome"))

    assert outcome.metadata["state"] == "failed"
    refute Map.has_key?(outcome.metadata, "failure_reason")
  end

  test "running a query needs queries.run, not a built-in role", context do
    enable(context.owner, [@disk])

    for scope <- [context.owner, context.admin, context.member] do
      assert {:error, :forbidden} = Jobs.create_job(scope, context.agent.id, @disk, %{})
    end

    grant(context.owner, context.member, ~w(queries.run))
    assert {:ok, _job} = Jobs.create_job(context.member, context.agent.id, @disk, %{})

    # queries.run grants no other observe job.
    assert {:error, :forbidden} = Jobs.create_job(context.member, context.agent.id, @collect, %{})
  end

  test "a sensitive query also needs queries.run_sensitive", context do
    enable(context.owner, [@packages])
    grant(context.owner, context.admin, ~w(queries.run))

    assert {:error, :forbidden} =
             Jobs.create_job(context.admin, context.agent.id, @packages, %{"name" => "ssl"})

    grant(context.owner, context.member, ~w(queries.run queries.run_sensitive))

    assert {:ok, job} =
             Jobs.create_job(context.member, context.agent.id, @packages, %{"name" => "ssl"})

    assert job.parameters == %{"name" => "ssl"}
  end

  test "parameters are validated before anything is stored", context do
    enable(context.owner, [@packages])
    grant(context.owner, context.owner, ~w(queries.run queries.run_sensitive))

    assert {:error, %Ecto.Changeset{}} =
             Jobs.create_job(context.owner, context.agent.id, @packages, %{"cmd" => "id"})

    assert Jobs.list_jobs(context.owner) == []
  end

  test "revoking the permission stops new queries at once", context do
    enable(context.owner, [@disk])
    assignment = grant(context.owner, context.member, ~w(queries.run))
    assert {:ok, _job} = Jobs.create_job(context.member, context.agent.id, @disk, %{})

    {:ok, _} = Assignments.unassign(context.owner, assignment.id)

    # The member's scope still caches the permission; the transaction does not.
    assert {:error, :forbidden} = Jobs.create_job(context.member, context.agent.id, @disk, %{})
  end

  test "cancelling a query needs the query's permissions", context do
    enable(context.owner, [@disk])
    grant(context.owner, context.member, ~w(queries.run))
    {:ok, job} = Jobs.create_job(context.member, context.agent.id, @disk, %{})

    # The admin holds jobs.request, which is not enough.
    assert {:error, :forbidden} = Jobs.cancel_job(context.admin, job.id)
    assert {:ok, %{state: "cancelled"}} = Jobs.cancel_job(context.member, job.id)

    {:ok, collect} = Jobs.create_job(context.admin, context.agent.id, @collect, %{})
    assert {:error, :forbidden} = Jobs.cancel_job(context.member, collect.id)
  end
end
