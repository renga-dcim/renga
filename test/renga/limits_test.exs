defmodule Renga.LimitsTest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures

  alias Renga.DeploymentAudit
  alias Renga.DeploymentAudit.Event
  alias Renga.Inventory.ChangeEvent
  alias Renga.Limits

  test "an organization gets the deployment default until an operator overrides it" do
    organization = organization_fixture()
    other = organization_fixture()

    assert Limits.get(organization.id, :job_creation_rate) == 10_000

    :ok =
      Limits.set(organization, [job_creation_rate: 600], Renga.DeploymentAudit.operator("test"))

    assert Limits.get(organization.id, :job_creation_rate) == 600
    assert Limits.get(other.id, :job_creation_rate) == 10_000

    :ok =
      Limits.set(organization, [job_creation_rate: 700], Renga.DeploymentAudit.operator("test"))

    assert Limits.get(organization.id, :job_creation_rate) == 700

    :ok = Limits.clear(organization, :job_creation_rate, Renga.DeploymentAudit.operator("test"))
    assert Limits.get(organization.id, :job_creation_rate) == 10_000
  end

  test "list/1 says where each value comes from" do
    organization = organization_fixture()
    :ok = Limits.set(organization, [job_creation_rate: 5], Renga.DeploymentAudit.operator("test"))

    assert [%{name: :job_creation_rate, value: 5, default: 10_000, overridden?: true}] =
             Limits.list(organization)
  end

  test "parse_name/1 accepts only known limits" do
    assert Limits.parse_name("job_creation_rate") == {:ok, :job_creation_rate}
    assert Limits.parse_name("anything_else") == :error
  end

  describe "set/3 and clear/3" do
    setup do
      %{organization: organization_fixture(), context: DeploymentAudit.operator("alice")}
    end

    test "record each change for the deployment and the organization", %{
      organization: organization,
      context: context
    } do
      :ok = Limits.set(organization, [job_creation_rate: 600], context)
      :ok = Limits.set(organization, [job_creation_rate: 600], context)
      :ok = Limits.clear(organization, :job_creation_rate, context)
      :ok = Limits.clear(organization, :job_creation_rate, context)

      assert Repo.all(
               from event in Event,
                 where: event.invocation_id == ^context.invocation_id,
                 order_by: event.inserted_at,
                 select: {event.operation, event.changed, event.organization_name}
             ) == [
               {"limits.set", ["job_creation_rate"], organization.name},
               {"limits.set", [], organization.name},
               {"limits.clear", ["job_creation_rate"], organization.name},
               {"limits.clear", [], organization.name}
             ]

      assert Repo.all(
               from event in ChangeEvent,
                 where: event.organization_id == ^organization.id,
                 order_by: event.occurred_at,
                 select: {event.kind, event.old_value, event.new_value, event.metadata}
             ) == [
               {"limit_set", nil, nil, %{"operator" => "operator: alice"}},
               {"limit_cleared", nil, nil, %{"operator" => "operator: alice"}}
             ]
    end

    test "apply every setting or none, and refuse values out of range", %{
      organization: organization,
      context: context
    } do
      for settings <- [
            [job_creation_rate: -1],
            [job_creation_rate: Limits.max_value() + 1],
            [job_creation_rate: 5, nonexistent: 1],
            [job_creation_rate: 1, job_creation_rate: 2],
            []
          ] do
        assert Limits.set(organization, settings, context) == {:error, :invalid}
      end

      assert Limits.get(organization.id, :job_creation_rate) == 10_000

      assert Repo.all(from event in Event, select: {event.outcome, event.reason}) ==
               List.duplicate({"rejected", "invalid"}, 5)

      :ok = Limits.set(organization, [job_creation_rate: 0], context)
      assert Limits.get(organization.id, :job_creation_rate) == 0
    end
  end
end
