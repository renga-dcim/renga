defmodule Renga.FindingsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.FindingsFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog.HardwareMatchFinding
  alias Renga.DCIM.PlacementFinding
  alias Renga.Findings
  alias Renga.Findings.Finding
  alias Renga.Inventory
  alias Renga.Inventory.Changes

  setup do
    organization = organization_fixture()
    member = member_scope(organization, "member")

    {:ok, resource} =
      Inventory.create_resource(member_scope(organization, "admin"), %{
        kind: "server",
        name: "web-01"
      })

    %{organization: organization, scope: member, resource: resource}
  end

  describe "list_findings/2" do
    test "reads every domain as one queue, drift first, newest observation first", context do
      component = component_finding(context, "component_drift", minutes_ago: 1)
      match = finding(context, HardwareMatchFinding, "ambiguous_catalog_match", minutes_ago: 3)
      placement = finding(context, PlacementFinding, "unknown_location", minutes_ago: 2)
      topology = topology_finding(context, "missing_vlan", minutes_ago: 4)

      {findings, 4} = Findings.list_findings(context.scope)

      assert Enum.map(findings, &{&1.domain, &1.id}) == [
               {"component", component.id},
               {"topology", topology.id},
               {"placement", placement.id},
               {"hardware_match", match.id}
             ]

      assert %Finding{interface_name: "eth0", group: "drift"} = Enum.at(findings, 1)
      assert Enum.all?(findings, &(&1.resource.id == context.resource.id and &1.state == :open))
    end

    test "groups drift apart from health and counts each", context do
      component_finding(context, "component_drift")
      component_finding(context, "ambiguous_component_identity", key: "evidence:1")
      finding(context, PlacementFinding, "unknown_location")

      assert {[%{kind: "component_drift"}], 1} =
               Findings.list_findings(context.scope, group: "drift")

      assert {health, 2} = Findings.list_findings(context.scope, group: "health")
      assert Enum.all?(health, &(&1.group == "health"))
      assert Findings.count_by_group(context.scope) == %{"drift" => 1, "health" => 2}
    end

    test "lists drift before health without a group filter", context do
      health = component_finding(context, "ambiguous_component_identity", key: "evidence:1")
      drift = component_finding(context, "component_drift", minutes_ago: 30)

      assert {[first, second], 2} = Findings.list_findings(context.scope)
      assert {first.id, second.id} == {drift.id, health.id}
    end

    test "filters by kind and by interface", context do
      component_finding(context, "component_drift")
      topology = topology_finding(context, "missing_vlan")

      assert {[%{id: id}], 1} = Findings.list_findings(context.scope, kind: "missing_vlan")
      assert id == topology.id

      assert {[%{id: ^id}], 1} =
               Findings.list_findings(context.scope, interface_id: topology.interface_id)
    end

    test "never shows another organization's findings", context do
      other = organization_fixture()

      {:ok, other_resource} =
        Inventory.create_resource(member_scope(other, "admin"), %{kind: "server", name: "x"})

      component_finding(
        %{context | organization: other, resource: other_resource},
        "component_drift"
      )

      assert {[], 0} = Findings.list_findings(context.scope)
    end

    test "lists resolved findings only when asked", context do
      component_finding(context, "component_drift", status: "resolved")

      assert {[], 0} = Findings.list_findings(context.scope)
      assert {[%{state: :resolved}], 1} = Findings.list_findings(context.scope, state: "resolved")
    end
  end

  describe "workflow" do
    test "assigning keeps the finding open and filters by assignee", context do
      component_finding(context, "component_drift")
      [finding] = open_findings(context)

      assert {:ok, workflow} = Findings.assign(context.scope, finding, context.scope.user.id)
      assert workflow.assignee_user_id == context.scope.user.id

      assert {[%{workflow: %{assignee_user: user}}], 1} =
               Findings.list_findings(context.scope, assignee: context.scope.user.id)

      assert user.id == context.scope.user.id
      assert {[], 0} = Findings.list_findings(context.scope, assignee: :unassigned)
    end

    test "only active owners, admins, and members can be assigned", context do
      component_finding(context, "component_drift")
      [finding] = open_findings(context)
      viewer = member_scope(context.organization, "viewer")
      outsider = user_fixture()

      assert {:error, :invalid_assignee} = Findings.assign(context.scope, finding, viewer.user.id)
      assert {:error, :invalid_assignee} = Findings.assign(context.scope, finding, outsider.id)

      assignable = Enum.map(Findings.assignable_users(context.scope), & &1.id)
      assert context.scope.user.id in assignable
      refute viewer.user.id in assignable
    end

    test "a snooze leaves the open queue until it passes", context do
      component_finding(context, "component_drift")
      [finding] = open_findings(context)
      until = DateTime.add(DateTime.utc_now(), 3600)

      assert {:ok, _workflow} = Findings.snooze(context.scope, finding, until)
      assert {[], 0} = Findings.list_findings(context.scope)
      assert {[%{state: :snoozed}], 1} = Findings.list_findings(context.scope, state: "snoozed")

      assert {:error, %Ecto.Changeset{}} =
               Findings.snooze(context.scope, finding, DateTime.add(DateTime.utc_now(), -60))

      assert {:ok, _workflow} = Findings.snooze(context.scope, finding, nil)
      assert {[%{state: :open}], 1} = Findings.list_findings(context.scope)
    end

    test "an exception needs a reason and returns to the queue when it expires", context do
      component_finding(context, "component_drift")
      [finding] = open_findings(context)

      assert {:error, changeset} =
               Findings.accept_exception(context.scope, finding, %{"exception_reason" => " "})

      assert "explain why this is acceptable" in errors_on(changeset).exception_reason

      expires_at = DateTime.add(DateTime.utc_now(), 2, :second)

      assert {:ok, workflow} =
               Findings.accept_exception(context.scope, finding, %{
                 "exception_reason" => "Spare DIMM pulled for RMA",
                 "exception_expires_at" => expires_at
               })

      assert workflow.exception_by_user_id == context.scope.user.id
      assert {[], 0} = Findings.list_findings(context.scope)

      assert [%{state: :excepted}] =
               Findings.list_resource_exceptions(context.scope, context.resource.id)

      # Expiry needs no job: the queue compares against the current time.
      Renga.Repo.update_all(Renga.Findings.Workflow,
        set: [exception_expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert {[%{state: :open}], 1} = Findings.list_findings(context.scope)
      assert Findings.list_resource_exceptions(context.scope, context.resource.id) == []
    end

    test "state follows the finding identity when a resolved finding recurs", context do
      first = component_finding(context, "component_drift")
      [finding] = open_findings(context)

      {:ok, _workflow} =
        Findings.accept_exception(context.scope, finding, %{"exception_reason" => "Known"})

      first
      |> Ecto.Changeset.change(status: "resolved", resolved_at: DateTime.utc_now())
      |> Repo.update!()

      recurrence = component_finding(context, "component_drift")

      assert {[%{id: id, state: :excepted}], 1} =
               Findings.list_findings(context.scope, state: "excepted")

      assert id == recurrence.id
    end

    test "expired exceptions must get a future or explicitly cleared expiry", context do
      component_finding(context, "component_drift")
      [finding] = open_findings(context)
      past = DateTime.add(Renga.Time.utc_now_ms(), -60)

      {:ok, workflow} =
        Findings.accept_exception(context.scope, finding, %{"exception_reason" => "Known"})

      Repo.update!(Ecto.Changeset.change(workflow, exception_expires_at: past))

      for attrs <- [
            %{"exception_reason" => "Again"},
            %{"exception_reason" => "Again", "exception_expires_at" => past}
          ] do
        assert {:error, changeset} = Findings.accept_exception(context.scope, finding, attrs)
        assert "must be in the future" in errors_on(changeset).exception_expires_at
      end

      finding = Findings.get_finding!(context.scope, finding.domain, finding.id)
      assert length(Findings.list_history(context.scope, finding)) == 1

      assert {:ok, _} =
               Findings.accept_exception(context.scope, finding, %{
                 "exception_reason" => "Indefinite",
                 "exception_expires_at" => nil
               })

      assert {[%{state: :excepted}], 1} = Findings.list_findings(context.scope, state: "excepted")
    end

    test "old resolved occurrences cannot clear a recurrence's workflow", context do
      first = component_finding(context, "component_drift")
      [finding] = open_findings(context)
      {:ok, _} = Findings.assign(context.scope, finding, context.scope.user.id)
      {:ok, _} = Findings.snooze(context.scope, finding, DateTime.add(DateTime.utc_now(), 3600))

      {:ok, workflow} =
        Findings.accept_exception(context.scope, finding, %{"exception_reason" => "Known"})

      Repo.update!(
        Ecto.Changeset.change(first, status: "resolved", resolved_at: DateTime.utc_now())
      )

      component_finding(context, "component_drift")

      assert {:error, :resolved} = Findings.assign(context.scope, finding, nil)
      assert {:error, :resolved} = Findings.snooze(context.scope, finding, nil)
      assert {:error, :resolved} = Findings.remove_exception(context.scope, finding)
      assert Repo.get!(Renga.Findings.Workflow, workflow.id) == workflow
      assert length(Findings.list_history(context.scope, %{finding | workflow: workflow})) == 3
    end

    test "resolved findings cannot be snoozed, assigned, or excepted", context do
      component_finding(context, "component_drift", status: "resolved")
      {[finding], 1} = Findings.list_findings(context.scope, state: "resolved")

      assert {:error, :resolved} = Findings.assign(context.scope, finding, context.scope.user.id)

      assert {:error, :resolved} =
               Findings.snooze(context.scope, finding, DateTime.add(DateTime.utc_now(), 60))

      assert {:error, :resolved} =
               Findings.accept_exception(context.scope, finding, %{"exception_reason" => "x"})
    end

    test "viewers and members of other organizations cannot change workflow", context do
      component_finding(context, "component_drift")
      [finding] = open_findings(context)
      viewer = member_scope(context.organization, "viewer")
      stranger = member_scope(organization_fixture(), "admin")

      assert {:error, :forbidden} = Findings.assign(viewer, finding, nil)
      assert {:error, :not_found} = Findings.snooze(stranger, finding, nil)
      refute Findings.can_change_workflow?(viewer)
      assert Findings.can_change_workflow?(context.scope)
    end

    test "every change is recorded in Activity with its actor and announced", context do
      topology_finding(context, "missing_vlan")
      [finding] = open_findings(context)
      :ok = Changes.subscribe(context.scope)

      {:ok, _workflow} = Findings.assign(context.scope, finding, context.scope.user.id)
      assert_receive {:inventory_changed, _organization_id}

      {:ok, _workflow} =
        Findings.accept_exception(context.scope, finding, %{"exception_reason" => "Lab VLAN"})

      {:ok, _workflow} = Findings.remove_exception(context.scope, finding)

      finding = Findings.get_finding!(context.scope, "topology", finding.id)
      history = Findings.list_history(context.scope, finding)

      assert Enum.map(history, & &1.kind) ==
               ~w(finding_exception_removed finding_exception finding_assigned)

      assert Enum.all?(history, &(&1.actor_user.id == context.scope.user.id))
      assert Enum.all?(history, &(&1.resource_id == context.resource.id))
      assert hd(history).old_value == %{"reason" => "Lab VLAN", "expires_at" => nil}
      assert List.last(history).new_value["assignee"] == context.scope.user.email
    end
  end

  defp open_findings(context) do
    {findings, _total} = Findings.list_findings(context.scope)
    findings
  end

  defp component_finding(context, kind, opts \\ []),
    do: component_finding_fixture(context.resource, kind, opts)

  defp finding(context, schema, kind, opts \\ []),
    do: resource_finding_fixture(schema, context.resource, kind, opts)

  defp topology_finding(context, kind, opts \\ []) do
    {:ok, interface} =
      Inventory.create_interface(
        member_scope(context.organization, "admin"),
        context.resource.id,
        %{
          name: "eth0"
        }
      )

    topology_finding_fixture(interface, kind, opts)
  end

  defp member_scope(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Renga.Accounts.scope_for_user(user, organization.id)
  end
end
