defmodule Renga.Jobs.TargetBindingsTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Inventory.InstallationKeys
  alias Renga.Jobs
  alias Renga.Jobs.TargetBindings

  @restart "test.restart@1"

  setup do
    %{organization: organization} = context = job_organization_fixture()

    organization
    |> Ecto.Changeset.change(settings: %{"jobs" => %{"allowed_capabilities" => [@restart]}})
    |> Repo.update!()

    agent = agent_fixture(organization, [@restart])
    resource = reported_resource_fixture(organization, agent)
    Map.merge(context, %{agent: agent, resource: resource})
  end

  defp present_new_key(agent) do
    {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, key} =
      Repo.transaction(fn ->
        InstallationKeys.present!(
          agent,
          %{algorithm: "ed25519", public_key: public_key},
          Renga.Time.utc_now_ms()
        )
      end)

    key
  end

  # Another installation reports the same resource, as a shared intake key can.
  defp also_reports(%{system_scope: scope, resource: resource}, agent) do
    {:ok, observation} =
      Renga.Inventory.create_observation(scope, agent.source_id, %{
        observation_id: "report-#{System.unique_integer([:positive])}",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{"hostname" => resource.name}
      })

    {:ok, _claim} =
      Renga.Inventory.create_resource_identifier_claim(scope, agent.source_id, observation.id, %{
        resource_id: resource.id,
        kind: "hostname",
        value: resource.name,
        confidence: 100
      })
  end

  defp queue(context) do
    Jobs.create_system_job(
      context.organization.id,
      context.agent.id,
      @restart,
      %{"service" => "sshd"},
      resource_id: context.resource.id
    )
  end

  test "binds a reported resource to an installation with an approved key", context do
    %{scope: scope, organization: organization, agent: agent, resource: resource} = context
    {key, _private} = approved_key_fixture(organization, agent)

    assert [{candidate, ^key}] = TargetBindings.candidates(scope, resource.id)
    assert candidate.id == agent.id

    assert {:ok, binding} = TargetBindings.bind(scope, resource.id, agent.id, key.fingerprint)
    assert binding.version == 1
    assert binding.approved_by_user_id == scope.user.id
    assert TargetBindings.current(scope, resource.id).id == binding.id
  end

  test "refuses installations whose key is pending, changed, or that do not report the resource",
       context do
    %{scope: scope, organization: organization, agent: agent, resource: resource} = context
    pending = present_new_key(agent)

    assert {:error, :key_changed} =
             TargetBindings.bind(scope, resource.id, agent.id, pending.fingerprint)

    {key, _private} = approved_key_fixture(organization, agent)
    assert {:error, :key_changed} = TargetBindings.bind(scope, resource.id, agent.id, "SHA256:x")

    stranger = agent_fixture(organization, [@restart])
    {stranger_key, _private} = approved_key_fixture(organization, stranger)

    assert {:error, :agent_not_for_resource} =
             TargetBindings.bind(scope, resource.id, stranger.id, stranger_key.fingerprint)

    assert {:error, :forbidden} =
             TargetBindings.bind(
               member_scope(organization, "member"),
               resource.id,
               agent.id,
               key.fingerprint
             )
  end

  test "privileged jobs need a binding to the agent they target", context do
    assert {:error, :target_not_bound} = queue(context)

    other = agent_fixture(context.organization, [@restart])
    also_reports(context, other)
    {key, _private} = approved_key_fixture(context.organization, other)

    {:ok, _binding} =
      TargetBindings.bind(context.scope, context.resource.id, other.id, key.fingerprint)

    assert {:error, :target_not_bound} = queue(context)
  end

  test "rebinding versions the binding and fails jobs queued under the old one", context do
    %{scope: scope, organization: organization, agent: agent, resource: resource} = context
    {key, _private} = approved_key_fixture(organization, agent)
    {:ok, first} = TargetBindings.bind(scope, resource.id, agent.id, key.fingerprint)
    {:ok, job} = queue(context)
    assert job.target_binding_version == 1

    {:ok, second} = TargetBindings.bind(scope, resource.id, agent.id, key.fingerprint)
    assert second.version == 2
    assert Repo.reload!(first).revoked_reason == "replaced"

    failed = Repo.reload!(job)
    assert failed.state == "failed"
    assert failed.failure_reason == "binding_changed"
  end

  test "revoking fails queued jobs and leaves the resource unbound", context do
    %{scope: scope, organization: organization, agent: agent, resource: resource} = context
    {key, _private} = approved_key_fixture(organization, agent)
    {:ok, binding} = TargetBindings.bind(scope, resource.id, agent.id, key.fingerprint)
    {:ok, job} = queue(context)

    assert {:ok, revoked} = TargetBindings.revoke(scope, binding.id)
    assert revoked.status == "revoked"
    assert TargetBindings.current(scope, resource.id) == nil
    assert Repo.reload!(job).failure_reason == "binding_changed"
    assert {:error, :target_not_bound} = queue(context)

    descriptions =
      scope
      |> Renga.Inventory.list_change_events(resource.id)
      |> Enum.filter(&(&1.field == "target_binding"))
      |> Enum.map(&RengaWeb.ChangeDescription.describe/1)
      |> Enum.sort()

    assert descriptions == [
             "Bound privileged jobs to #{agent.name} (key #{key.fingerprint})",
             "Unbound privileged jobs from #{agent.name}"
           ]
  end

  test "replacing the bound key revokes the binding", context do
    %{scope: scope, organization: organization, agent: agent, resource: resource} = context
    {key, _private} = approved_key_fixture(organization, agent)
    {:ok, binding} = TargetBindings.bind(scope, resource.id, agent.id, key.fingerprint)
    {:ok, job} = queue(context)

    _replacement = present_new_key(agent)

    assert Repo.reload!(binding).revoked_reason == "key_replaced"
    assert Repo.reload!(job).failure_reason == "binding_changed"
  end
end
