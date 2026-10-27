defmodule Renga.Operators.OrganizationLifecycleTest do
  use Renga.DataCase, async: true
  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.DeploymentAudit
  alias Renga.DeploymentAudit.Event
  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias Renga.Operators.OrganizationLifecycle, as: Lifecycle

  setup do
    Map.put(job_organization_fixture(), :context, DeploymentAudit.operator("containment-test"))
  end

  test "suspension contains queued and running work without claiming an outcome; resume never reruns",
       ctx do
    agent = agent_fixture(ctx.organization)
    {:ok, running} = Jobs.create_job(ctx.scope, agent.id, "inventory.collect@1", %{})
    {:ok, [{_, token}]} = Jobs.lease_jobs(ctx.system_scope, agent, ["inventory.collect@1"], 1)
    {:ok, _} = Jobs.report(ctx.system_scope, agent, running.id, token, "started", %{})
    {:ok, queued} = Jobs.create_job(ctx.scope, agent.id, "inventory.collect@1", %{})

    assert {:ok, %{status: "disabled"}} =
             Lifecycle.change(ctx.organization.id, "suspend", ctx.context)

    assert Repo.get!(Job, queued.id).state == "cancelled"
    held = Repo.get!(Job, running.id)
    assert held.state == "running"
    assert held.cancel_requested_at
    assert held.finished_at == nil

    assert {:error, :forbidden} =
             Jobs.lease_jobs(ctx.system_scope, agent, ["inventory.collect@1"], 1)

    assert {:error, :forbidden} =
             Jobs.report(ctx.system_scope, agent, running.id, token, "succeeded", %{})

    refute Accounts.scope_for_user(ctx.scope.user, ctx.organization.id).organization_id

    assert {:ok, _} = Lifecycle.change(ctx.organization.id, "resume", ctx.context)
    assert Repo.get!(Job, queued.id).state == "cancelled"
    assert Repo.get!(Job, running.id).cancel_requested_at == held.cancel_requested_at

    assert {:error, :lease_not_held} =
             Jobs.report(ctx.system_scope, agent, running.id, token, "succeeded", %{})
  end

  test "a running imperative job remains uncertain on lost lease", ctx do
    ctx.organization
    |> Ecto.Changeset.change(
      settings: %{"jobs" => %{"allowed_capabilities" => ["test.restart@1"]}}
    )
    |> Repo.update!()

    agent = agent_fixture(ctx.organization, ["test.restart@1"])

    %{resource: resource, private_key: private_key} =
      target_binding_fixture(ctx.organization, agent)

    {:ok, job} =
      Jobs.create_system_job(
        ctx.organization.id,
        agent.id,
        "test.restart@1",
        %{"service" => "sshd"},
        resource_id: resource.id
      )

    {:ok, [{_, token}]} =
      lease_privileged(ctx.system_scope, agent, ["test.restart@1"], private_key)

    {:ok, _} = Jobs.report(ctx.system_scope, agent, job.id, token, "started", %{})
    {:ok, _} = Lifecycle.change(ctx.organization.id, "suspend", ctx.context)
    Jobs.sweep(DateTime.add(Renga.Time.utc_now_ms(), 61))
    assert Repo.get!(Job, job.id).state == "uncertain"
  end

  test "reactivation reconciles stale SCIM grants while preserving manual owners", ctx do
    connection = Renga.ScimFixtures.scim_connection_fixture(ctx.scope)
    member = member_scope(ctx.organization, "member")

    Accounts.get_membership_for_user(ctx.organization, member.user.id)
    |> Ecto.Changeset.change(scim_connection_id: connection.id)
    |> Repo.update!()

    {:ok, _} = Lifecycle.change(ctx.organization.id, "schedule_deletion", ctx.context)
    connection |> Ecto.Changeset.change(disabled_at: Renga.Time.utc_now_ms()) |> Repo.update!()
    {:ok, _} = Lifecycle.change(ctx.organization.id, "cancel_deletion", ctx.context)

    refute Accounts.scope_for_user(member.user, ctx.organization.id).organization_id
    assert Accounts.scope_for_user(ctx.scope.user, ctx.organization.id).organization_id
  end

  test "deletion retries keep one deadline and one notice, cancellation restores access", ctx do
    {:ok, first} = Lifecycle.change(ctx.organization.id, "schedule_deletion", ctx.context)
    {:ok, repeated} = Lifecycle.change(ctx.organization.id, "schedule_deletion", ctx.context)
    assert DateTime.diff(first.deletion_due_at, first.deletion_scheduled_at, :day) == 30
    assert repeated.deletion_due_at == first.deletion_due_at
    assert Repo.aggregate("organization_lifecycle_notices", :count) == 1

    assert {:error, :not_due} =
             Lifecycle.purge_due(first.id, DateTime.add(first.deletion_due_at, -1))

    assert {:ok, %{status: "active", deletion_due_at: nil}} =
             Lifecycle.change(first.id, "cancel_deletion", ctx.context)

    assert {:error, :not_due} = Lifecycle.purge_due(first.id, first.deletion_due_at)
    assert {:ok, %{status: "active"}} = Lifecycle.change(first.id, "resume", ctx.context)
    assert Repo.aggregate("organization_lifecycle_notices", :count) == 2
  end

  test "committed owner notices are delivered and successful delivery is not repeated", ctx do
    {:ok, _} = Lifecycle.change(ctx.organization.id, "schedule_deletion", ctx.context)
    assert {:ok, _} = Lifecycle.deliver_notices()
    subject = "Organization lifecycle: #{ctx.organization.name}"
    assert_received {:email, %{subject: ^subject} = email}
    assert email.to == [{"", ctx.scope.user.email}]
    assert email.text_body =~ "Deletion deadline:"
    assert email.text_body =~ "/organizations/deletions"
    assert {:ok, _} = Lifecycle.deliver_notices()
    refute_received {:email, %{subject: ^subject}}
  end

  test "resume atomically cancels deletion; purge cannot be resumed or cancelled", ctx do
    {:ok, scheduled} = Lifecycle.change(ctx.organization.id, "schedule_deletion", ctx.context)

    assert {:ok, %{status: "active", deletion_due_at: nil}} =
             Lifecycle.change(scheduled.id, "resume", ctx.context)

    {:ok, scheduled} = Lifecycle.change(scheduled.id, "schedule_deletion", ctx.context)
    scheduled |> Ecto.Changeset.change(status: "purging") |> Repo.update!()
    assert {:error, :purging} = Lifecycle.change(scheduled.id, "resume", ctx.context)
    assert {:error, :purging} = Lifecycle.change(scheduled.id, "cancel_deletion", ctx.context)
  end

  test "purge cascades tenant data and archive but preserves shared people and deployment attribution" do
    ctx = Renga.TransfersFixtures.round_trip_organization()
    other = Renga.InventoryFixtures.organization_fixture()

    {:ok, {provider, revision}} =
      Renga.Accounts.IdentityProviders.create(
        %{
          "id" => "purged-#{System.unique_integer([:positive])}",
          "kind" => "oidc",
          "issuer" => "https://login.example.test",
          "display_name" => "Tenant SSO",
          "client_id" => "renga",
          "client_secret" => "purge-this-secret"
        },
        {:operator, "fixture"},
        organization_id: ctx.organization.id
      )

    identity =
      Repo.insert!(%Renga.Accounts.UserIdentity{
        user_id: ctx.owner.user.id,
        provider_id: provider.id,
        subject: "shared-owner"
      })

    Renga.InventoryFixtures.organization_membership_fixture(ctx.owner.user, other, %{
      role: "owner"
    })

    context = DeploymentAudit.operator("purge-test")
    {:ok, scheduled} = Lifecycle.change(ctx.organization.id, "schedule_deletion", context)
    assert {:ok, _} = Lifecycle.purge_due(scheduled.id, scheduled.deletion_due_at)
    assert Repo.get(Organization, scheduled.id) == nil
    assert Repo.get(Job, ctx.job.id) == nil
    assert Repo.get(Renga.Inventory.Resource, ctx.resource.id) == nil
    assert Accounts.get_user!(ctx.owner.user.id)
    assert Accounts.get_user_organization_membership(ctx.owner.user, other.id)
    assert Repo.get!(Renga.Accounts.UserIdentity, identity.id).user_id == ctx.owner.user.id
    tombstone = Repo.get!(Renga.Accounts.IdentityProvider, provider.id)
    assert tombstone.organization_id == scheduled.id
    assert tombstone.removed_at
    refute tombstone.enabled
    refute Renga.Accounts.IdentityProviders.get(provider.id)

    refute Repo.get!(Renga.Accounts.IdentityProviderRevision, revision.id).client_secret_ciphertext

    assert %{organization_name: name, organization_id: id, outcome: "succeeded"} =
             Repo.one!(from e in Event, where: e.operation == "organization.purge")

    assert name == scheduled.name
    assert id == scheduled.id
  end

  test "only current owners can recover; cancellation is attributed and safely repeatable", ctx do
    viewer = member_scope(ctx.organization, "viewer")
    {:ok, _} = Lifecycle.change(ctx.organization.id, "schedule_deletion", ctx.context)
    assert {:error, :forbidden} = Lifecycle.owner_scope(viewer.user, ctx.organization.id)

    assert {:error, :forbidden} =
             Lifecycle.cancel_by_owner(viewer.user, ctx.organization.id, "request-denied")

    assert {:ok, _} = Lifecycle.owner_scope(ctx.scope.user, ctx.organization.id)

    assert {:ok, %{status: "active"}} =
             Lifecycle.cancel_by_owner(ctx.scope.user, ctx.organization.id, "request-owner")

    assert {:ok, %{status: "active"}} =
             Lifecycle.cancel_by_owner(ctx.scope.user, ctx.organization.id, "request-retry")

    assert %{actor_user_id: actor_id} =
             Repo.one!(from e in Event, where: e.invocation_id == "request-owner")

    assert actor_id == ctx.scope.user.id
  end
end
