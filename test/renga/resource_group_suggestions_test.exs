defmodule Renga.ResourceGroupSuggestionsTest do
  @moduledoc """
  Group triage rules (RFD 18) suggest membership; only a person's
  acceptance changes it.
  """
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.TriageFixtures

  alias Renga.Inventory
  alias Renga.ResourceGroups
  alias Renga.ResourceGroups.Member
  alias Renga.TriageRules

  setup do
    organization = organization_fixture()
    admin = member_scope(organization, "admin")
    member = member_scope(organization, "member")
    {:ok, staging} = ResourceGroups.create_group(admin, %{name: "Staging"})

    %{organization: organization, admin: admin, member: member, staging: staging}
  end

  defp staging_rule(context, attrs \\ %{}) do
    TriageRules.create_rule(
      context.admin,
      Map.merge(
        %{
          "kind" => "group",
          "name" => "Staging hosts",
          "hostname_pattern" => "stg-*",
          "resource_group_id" => context.staging.id
        },
        attrs
      )
    )
  end

  test "a group rule needs a group and one signal", context do
    assert {:error, changeset} =
             TriageRules.create_rule(context.admin, %{"kind" => "group", "name" => "Empty"})

    assert "choose a group" in errors_on(changeset).resource_group_id
    assert "enter a hostname pattern such as web-*" in errors_on(changeset).hostname_pattern

    other = organization_fixture() |> member_scope("owner")
    {:ok, theirs} = ResourceGroups.create_group(other, %{name: "Theirs"})

    assert {:error, changeset} =
             staging_rule(context, %{"resource_group_id" => theirs.id})

    assert "is not in this organization" in errors_on(changeset).resource_group_id
  end

  test "a matching resource gets a suggestion and no membership", context do
    stg = server_fixture(context.admin, "stg-01", hostname: "stg-01")
    _prod = server_fixture(context.admin, "prd-01", hostname: "prd-01")

    assert {:ok, %{will_set: 1}} =
             TriageRules.preview(context.admin, %{
               "kind" => "group",
               "name" => "Preview",
               "hostname_pattern" => "stg-*",
               "resource_group_id" => context.staging.id
             })

    assert {:ok, %{applied: 1}} = staging_rule(context)

    assert [%{resource_id: resource_id, rule_name: "Staging hosts", status: "open"}] =
             ResourceGroups.list_suggestions(context.admin)

    assert resource_id == stg.id
    assert Repo.all(Member) == []
    assert ResourceGroups.list_resource_groups(context.admin, stg.id) == []
  end

  test "a collector label raises a suggestion as the resource reports", context do
    {:ok, _result} =
      staging_rule(context, %{
        "hostname_pattern" => nil,
        "label_key" => "env",
        "label_value" => "staging"
      })

    labelled = report_fixture(context.admin, "m-1", labels: %{"env" => "staging"})
    _other = report_fixture(context.admin, "m-2", labels: %{"env" => "prod"})

    assert [%{resource_id: resource_id}] = ResourceGroups.list_suggestions(context.admin)
    assert resource_id == labelled.id
  end

  test "a resource already in the group is not suggested", context do
    stg = server_fixture(context.admin, "stg-01", hostname: "stg-01")
    {:ok, 1} = ResourceGroups.add_members(context.admin, context.staging, [stg.id])

    assert {:ok, %{applied: 0}} = staging_rule(context)
    assert ResourceGroups.list_suggestions(context.admin) == []
  end
end
