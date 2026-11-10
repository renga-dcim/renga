defmodule Renga.QuotasTest do
  use Renga.DataCase, async: true
  import Renga.JobsFixtures
  alias Renga.{Inventory, Limits, Quotas}

  defp set(organization, settings),
    do: Limits.set(organization, settings, Renga.DeploymentAudit.operator("quota-test"))

  test "resource quota counts every envelope; only physical deletion frees capacity" do
    %{organization: org, scope: scope} = job_organization_fixture()
    :ok = set(org, resources: 1)
    assert {:ok, resource} = Inventory.create_resource(scope, %{kind: "server", name: "one"})
    assert Quotas.usage(org.id, :resources) == 1

    assert {:ok, resource} =
             Inventory.update_resource(scope, resource, %{lifecycle_state: "retired"})

    assert {:error, reason} = Inventory.create_resource(scope, %{kind: "server", name: "two"})
    assert Quotas.exceeded?(reason, :resources)
    assert Quotas.usage(org.id, :resources) == 1

    :ok = set(org, resources: 0)

    assert {:ok, resource} =
             Inventory.update_resource(scope, resource, %{display_name: "Still editable"})

    assert [%{name: "resources", used: 1, capacity: 0}] = Quotas.findings(scope)
    Repo.delete!(resource)
    assert Quotas.usage(org.id, :resources) == 0
    :ok = Limits.clear(org, :resources, Renga.DeploymentAudit.operator("quota-test"))
    assert Quotas.findings(scope) == []
    assert {:ok, _} = Inventory.create_resource(scope, %{kind: "server", name: "two"})
  end

  test "80 percent opens an owner finding immediately, including a lowered policy" do
    %{organization: org, scope: scope} = job_organization_fixture()
    :ok = set(org, resources: 5)
    for n <- 1..3, do: Inventory.create_resource(scope, %{kind: "server", name: "host-#{n}"})
    assert Quotas.findings(scope) == []
    assert {:ok, resource} = Inventory.create_resource(scope, %{kind: "server", name: "host-4"})
    assert [%{name: "resources", used: 4, capacity: 5}] = Quotas.findings(scope)
    assert Quotas.findings(member_scope(org, "admin")) == []
    Repo.delete!(resource)
    assert Quotas.findings(scope) == []
    :ok = set(org, resources: 3)
    assert [%{name: "resources", used: 3, capacity: 3}] = Quotas.findings(scope)
  end

  test "disabled agents and installation UUIDs remain charged, repeated check-in does not double-charge" do
    %{organization: org, system_scope: scope} = job_organization_fixture()
    :ok = set(org, agents: 1, installation_identities: 1)
    agent = agent_fixture(org)
    assert Quotas.usage(org.id, :agents) == 1
    assert Quotas.usage(org.id, :installation_identities) == 1

    assert {:ok, _} =
             Inventory.record_agent_check_in(scope, agent.source_id, %{
               installation_id: agent.installation_id
             })

    assert Quotas.usage(org.id, :agents) == 1
    agent |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
    assert Quotas.usage(org.id, :installation_identities) == 1
    Repo.delete!(agent)
    assert Quotas.usage(org.id, :agents) == 0
    assert Quotas.usage(org.id, :installation_identities) == 0
  end

  test "revocation releases an intake key once and rolled-back creation holds nothing" do
    %{organization: org, scope: scope} = job_organization_fixture()
    :ok = set(org, intake_keys: 1)
    assert {:ok, {key, _token}} = Inventory.create_intake_api_key(scope, %{name: "first"})
    assert {:error, reason} = Inventory.create_intake_api_key(scope, %{name: "second"})
    assert Quotas.exceeded?(reason, :intake_keys)
    assert Quotas.usage(org.id, :intake_keys) == 1
    assert {:ok, _} = Inventory.revoke_intake_api_key(scope, key.id)
    assert {:ok, _} = Inventory.revoke_intake_api_key(scope, key.id)
    assert Quotas.usage(org.id, :intake_keys) == 0

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               {:ok, _} = Inventory.create_intake_api_key(scope, %{name: "rolled back"})
               Repo.rollback(:cancelled)
             end)

    assert Quotas.usage(org.id, :intake_keys) == 0
    assert {:ok, _} = Inventory.create_intake_api_key(scope, %{name: "second"})
  end

  test "current owner assignments grant private findings access only while held" do
    %{organization: org, scope: owner} = job_organization_fixture()
    member = member_scope(org, "member")
    :ok = set(org, resources: 1)
    {:ok, _} = Inventory.create_resource(owner, %{kind: "server", name: "one"})

    for ending <- [:expired, :removed] do
      {:ok, assignment} =
        Renga.Assignments.assign(owner, member.membership_id, %{"role" => "owner"})

      assigned = Renga.Accounts.scope_for_user(member.user, org.id)
      assert [_] = Quotas.findings(assigned)
      assert {[finding], 1} = Renga.Findings.list_findings(assigned, domain: "quota")
      assert Renga.Findings.count_by_group(assigned)["health"] == 1
      assert Renga.Findings.get_finding(assigned, "quota", finding.id)
      assert {:ok, _} = Renga.Findings.assign(assigned, finding, member.user.id)

      case ending do
        :expired ->
          assignment
          |> Ecto.Changeset.change(valid_until: DateTime.add(Renga.Time.utc_now_ms(), -1))
          |> Repo.update!()

        :removed ->
          assert {:ok, _} = Renga.Assignments.unassign(owner, assignment.id)
      end

      assert Quotas.findings(assigned) == []
      assert {[], 0} = Renga.Findings.list_findings(assigned, domain: "quota")
      assert Renga.Findings.count_by_group(assigned)["health"] == 0
      assert Renga.Findings.get_finding(assigned, "quota", finding.id) == nil
      assert {:error, :not_found} = Renga.Findings.assign(assigned, finding, nil)
    end
  end

  test "quota findings use Inbox workflow without disclosing capacity to other members" do
    %{organization: org, scope: owner} = job_organization_fixture()
    admin = member_scope(org, "admin")
    :ok = set(org, resources: 1)
    {:ok, resource} = Inventory.create_resource(owner, %{kind: "server", name: "one"})
    assert {[finding], 1} = Renga.Findings.list_findings(owner, domain: "quota")
    assert finding.resource == nil
    assert finding.details == %{"quota" => "resources", "used" => 1, "capacity" => 1}
    assert Renga.Findings.count_by_group(owner)["health"] == 1
    assert {[], 0} = Renga.Findings.list_findings(admin, domain: "quota")
    assert Renga.Findings.count_by_group(admin)["health"] == 0
    assert Renga.Findings.get_finding(admin, "quota", finding.id) == nil
    assert {:error, :not_found} = Renga.Findings.assign(admin, finding, admin.user.id)

    assert {:ok, _} = Renga.Findings.assign(owner, finding, owner.user.id)
    until = DateTime.add(Renga.Time.utc_now_ms(), 3600)
    assert {:ok, _} = Renga.Findings.snooze(owner, finding, until)
    assert {[snoozed], 1} = Renga.Findings.list_findings(owner, domain: "quota", state: "snoozed")
    assert snoozed.workflow.assignee_user_id == owner.user.id

    assert {:ok, _} =
             Renga.Findings.accept_exception(owner, finding, %{
               exception_reason: "Capacity increase scheduled"
             })

    assert {[_], 1} = Renga.Findings.list_findings(owner, domain: "quota", state: "excepted")

    assert length(
             Renga.Findings.list_history(
               owner,
               Renga.Findings.get_finding!(owner, "quota", finding.id)
             )
           ) == 3

    Repo.delete!(resource)
    assert {[_], 1} = Renga.Findings.list_findings(owner, domain: "quota", state: "resolved")
    {:ok, _} = Inventory.create_resource(owner, %{kind: "server", name: "recurrence"})

    assert {[reopened], 1} =
             Renga.Findings.list_findings(owner, domain: "quota", state: "excepted")

    refute reopened.id == finding.id
    assert {:error, :not_found} = Renga.Findings.snooze(owner, finding, nil)

    # A connected owner page cannot retain private access after demotion.
    Repo.get!(Renga.Accounts.OrganizationMembership, owner.membership_id)
    |> Ecto.Changeset.change(role: "admin")
    |> Repo.update!()

    assert Renga.Findings.get_finding(owner, "quota", reopened.id) == nil
    assert {:error, :not_found} = Renga.Findings.assign(owner, reopened, owner.user.id)
    assert Renga.Findings.list_history(owner, snoozed) == []
    assert Quotas.findings(owner) == []
  end
end
