defmodule Renga.Jobs.QueryBatchTest do
  @moduledoc """
  RFD 12 fan-out: one request runs a query on every resource of a list whose
  agent offers it, as one batch that is created whole or not at all.
  """
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Roles

  @sockets "query.listening_sockets@1"
  @disk "query.disk_usage@1"

  setup do
    %{organization: organization, scope: owner} = job_organization_fixture()
    {:ok, _} = Jobs.update_settings(owner, %{allowed_capabilities: [@sockets, @disk]})

    member = member_scope(organization, "member")

    {:ok, role} =
      Roles.create_role(owner, %{
        "name" => "Sensitive queries",
        "permissions" => ~w(queries.run queries.run_sensitive)
      })

    {:ok, _} = Assignments.assign(owner, member.membership_id, %{"role" => role.id})

    offering = agent_fixture(organization, [@sockets, @disk])
    other = agent_fixture(organization, [@disk])

    %{
      organization: organization,
      owner: owner,
      runner: Accounts.scope_for_user(member.user, organization.id),
      offering: offering,
      web: reported_resource_fixture(organization, offering, "web-01"),
      db: reported_resource_fixture(organization, other, "db-01")
    }
  end

  test "batch_targets/3 maps each resource to an active agent offering the query", context do
    targets = Jobs.batch_targets(context.runner, @sockets, [context.web.id, context.db.id])

    assert targets == %{context.web.id => context.offering.id}

    assert map_size(Jobs.batch_targets(context.runner, @disk, [context.web.id, context.db.id])) ==
             2
  end

  test "creates a job per resource with an agent, sharing a batch id", context do
    assert {:ok, %{batch_id: batch_id, jobs: [job], skipped: skipped}} =
             Jobs.create_batch(context.runner, @sockets, %{"port" => 23}, [
               context.web.id,
               context.db.id
             ])

    assert skipped == [context.db.id]
    assert job.batch_id == batch_id
    assert job.resource_id == context.web.id
    assert job.agent_id == context.offering.id
    assert job.parameters == %{"port" => 23}
    assert [%{id: id}] = Jobs.list_jobs(context.runner, batch_id: batch_id)
    assert id == job.id
  end

  test "needs the query's permissions, like a single run", context do
    assert {:error, :forbidden} =
             Jobs.create_batch(context.owner, @disk, %{}, [context.web.id, context.db.id])

    assert Jobs.list_jobs(context.owner) == []
  end

  test "refuses the whole batch on invalid parameters", context do
    assert {:error, %Ecto.Changeset{}} =
             Jobs.create_batch(context.runner, @sockets, %{"port" => 0}, [context.web.id])

    assert Jobs.list_jobs(context.runner) == []
  end

  test "refuses a batch no agent can answer, or one too large", context do
    assert {:error, :no_agents} =
             Jobs.create_batch(context.runner, @sockets, %{}, [context.db.id])

    assert {:error, :no_agents} = Jobs.create_batch(context.runner, @sockets, %{}, [])

    too_many = for _ <- 0..Jobs.max_batch_size(), do: Ecto.UUID.generate()

    assert {:error, :batch_too_large} = Jobs.create_batch(context.runner, @sockets, %{}, too_many)
  end

  test "a query the organization has off is refused", context do
    {:ok, _} = Jobs.update_settings(context.owner, %{allowed_capabilities: [@disk]})

    assert {:error, :capability_not_allowed} =
             Jobs.create_batch(context.runner, @sockets, %{}, [context.web.id])
  end

  test "list_operational_resource_ids/3 lists a filtered list's ids", context do
    scope = context.runner
    options = [search: "web", kinds: [], lifecycle: nil]

    assert Inventory.list_operational_resource_ids(scope, options, 10) == [context.web.id]

    assert length(Inventory.list_operational_resource_ids(scope, [kinds: ["server"]], 10)) == 2
    assert length(Inventory.list_operational_resource_ids(scope, [kinds: ["server"]], 1)) == 1
  end
end
