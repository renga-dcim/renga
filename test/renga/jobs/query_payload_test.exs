defmodule Renga.Jobs.QueryPayloadTest do
  @moduledoc """
  RFD 12: a query's parameters, results, and the agent's reports are read
  only by people who hold its permissions now. Generic job metadata stays
  visible, and requesting a job grants no lasting access.
  """
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Roles

  @disk "query.disk_usage@1"
  @packages "query.packages@1"
  @packages_result %{
    "packages" => [
      %{"name" => "openssl", "version" => "3.0.2", "architecture" => nil, "manager" => "dpkg"}
    ],
    "truncated" => false
  }

  setup do
    %{organization: organization, scope: owner} = job_organization_fixture()
    agent = agent_fixture(organization, ["host.inventory", @disk, @packages])
    resource = reported_resource_fixture(organization, agent)
    allow(owner, ["inventory.collect@1", @disk, @packages])

    member = member_scope(organization, "member")
    sensitive = grant(owner, member, ~w(queries.run queries.run_sensitive))
    # The scope a page would build after the grant, caching the permissions.
    requester = Accounts.scope_for_user(member.user, organization.id)
    grant(owner, owner, ~w(queries.run))

    %{
      organization: organization,
      owner: owner,
      admin: member_scope(organization, "admin"),
      requester: requester,
      sensitive: sensitive,
      system: Accounts.scope_for(organization),
      agent: agent,
      resource: resource
    }
  end

  defp allow(owner, keys),
    do: {:ok, _} = Jobs.update_settings(owner, %{allowed_capabilities: keys})

  defp grant(owner, scope, permissions) do
    {:ok, role} =
      Roles.create_role(owner, %{
        "name" => "Queries #{System.unique_integer([:positive])}",
        "permissions" => permissions
      })

    {:ok, assignment} = Assignments.assign(owner, scope.membership_id, %{"role" => role.id})
    assignment
  end

  defp run(context, key, parameters, outcome) do
    {:ok, job} =
      Jobs.create_job(context.requester, context.agent.id, key, parameters,
        resource_id: context.resource.id
      )

    {:ok, [{_job, token}]} = Jobs.lease_jobs(context.system, context.agent, [key], 1)
    {:ok, _} = Jobs.report(context.system, context.agent, job.id, token, "started", %{})

    {:ok, _} =
      Jobs.report(context.system, context.agent, job.id, token, "progress", %{
        "message" => "reading dpkg status"
      })

    {:ok, job} =
      case outcome do
        {:succeeded, result} ->
          Jobs.report(context.system, context.agent, job.id, token, "succeeded", %{
            "result" => result
          })

        {:failed, reason} ->
          Jobs.report(context.system, context.agent, job.id, token, "failed", %{
            "reason" => reason
          })
      end

    job
  end

  defp agent_payloads(scope, job) do
    for event <- Jobs.list_events(scope, job), event.actor_type == "agent", do: event.payload
  end

  test "holders of both permissions read a sensitive query's payloads", context do
    job = run(context, @packages, %{"name" => "ssl"}, {:succeeded, @packages_result})

    read = Jobs.get_job(context.requester, job.id)
    refute read.payload_hidden
    assert read.parameters == %{"name" => "ssl"}
    assert read.result == @packages_result
    assert %{"message" => "reading dpkg status"} in agent_payloads(context.requester, job)
  end

  test "others see the job but not its parameters, result, or reports", context do
    job = run(context, @packages, %{"name" => "ssl"}, {:succeeded, @packages_result})

    # The admin holds jobs.request and the owner queries.run; neither is enough.
    for scope <- [context.admin, context.owner] do
      read = Jobs.get_job(scope, job.id)
      assert read.payload_hidden
      assert %{state: "succeeded", parameters: nil, result: nil} = read
      assert read.capability == "query.packages"
      assert read.requested_by_user_id == context.requester.user.id

      assert [listed] = Jobs.list_jobs(scope, capability: {"query.packages", 1})
      assert %{payload_hidden: true, parameters: nil, result: nil} = listed
      assert %{payload_hidden: true, result: nil} = Jobs.get_job!(scope, job.id)

      events = Jobs.list_events(scope, job)
      assert Enum.map(events, & &1.type) == ~w(created leased started progress succeeded)
      assert Enum.all?(agent_payloads(scope, job), &(&1 == %{}))
      assert Enum.all?(events, &(&1.payload_hidden == (&1.actor_type == "agent")))
    end
  end

  test "an inventory query's payload needs only queries.run", context do
    result = %{"filesystems" => [], "truncated" => false}
    job = run(context, @disk, %{}, {:succeeded, result})

    assert %{payload_hidden: false, result: ^result} = Jobs.get_job(context.owner, job.id)
    assert %{payload_hidden: true, result: nil} = Jobs.get_job(context.admin, job.id)
  end

  test "an agent's failure reason is payload, Renga's own reasons are not", context do
    job = run(context, @packages, %{}, {:failed, "rpmdb open failed: /var/lib/rpm/secret"})

    assert %{failure_reason: nil, payload_hidden: true} = Jobs.get_job(context.admin, job.id)
    assert %{failure_reason: "rpmdb" <> _} = Jobs.get_job(context.requester, job.id)

    {:ok, refused} =
      Jobs.create_job(context.requester, context.agent.id, @packages, %{},
        resource_id: context.resource.id
      )

    allow(context.owner, [@disk])
    {:ok, []} = Jobs.lease_jobs(context.system, context.agent, [@packages], 1)

    assert %{failure_reason: "capability_not_allowed", payload_hidden: true} =
             Jobs.get_job(context.admin, refused.id)
  end

  test "a job's events cannot be preloaded around the withholding", context do
    job = run(context, @packages, %{"name" => "ssl"}, {:succeeded, @packages_result})

    for preload <- [[:events], [events: :job], [resource: :claims]] do
      assert_raise ArgumentError, fn -> Jobs.get_job(context.admin, job.id, preload: preload) end
    end

    assert %{payload_hidden: true, agent: %{id: _}} =
             Jobs.get_job(context.admin, job.id, preload: [:resource, :agent, :requested_by_user])
  end

  test "Activity carries only the summary of a sensitive job", context do
    run(context, @packages, %{"name" => "ssl"}, {:failed, "rpmdb open failed"})

    outcome =
      context.owner
      |> Inventory.list_activity()
      |> Enum.find(&(&1.kind == "job_outcome"))

    assert outcome.metadata["state"] == "failed"
    assert outcome.metadata["title"] == "Packages"
    refute Map.has_key?(outcome.metadata, "failure_reason")
    refute inspect(outcome) =~ "rpmdb"
    refute inspect(outcome) =~ "ssl"
  end

  test "the requester loses access when the permission is revoked", context do
    job = run(context, @packages, %{"name" => "ssl"}, {:succeeded, @packages_result})
    assert %{payload_hidden: false} = Jobs.get_job(context.requester, job.id)

    {:ok, _} = Assignments.unassign(context.owner, context.sensitive.id)

    # The requester's scope still caches the permission; reads check the
    # database, and having asked for the job grants nothing.
    assert "queries.run_sensitive" in context.requester.permissions
    assert %{payload_hidden: true, result: nil} = Jobs.get_job(context.requester, job.id)
    assert [%{payload_hidden: true}] = Jobs.list_jobs(context.requester)
    assert Enum.all?(agent_payloads(context.requester, job), &(&1 == %{}))
  end

  test "a disabled member or machine scope reads no sensitive payload", context do
    job = run(context, @packages, %{}, {:succeeded, @packages_result})

    assert %{payload_hidden: true} = Jobs.get_job(context.system, job.id)

    {:ok, _} = Renga.Members.disable_member(context.owner, context.requester.membership_id)
    assert %{payload_hidden: true} = Jobs.get_job(context.requester, job.id)
  end
end
