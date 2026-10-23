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
  alias Renga.ResourceGroups.Suggestion
  alias Renga.TriageRules
  alias Renga.TriageRules.Rule

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

  test "accepting adds the resource as the accepting person", context do
    stg = server_fixture(context.admin, "stg-01", hostname: "stg-01")
    {:ok, _result} = staging_rule(context)
    [suggestion] = ResourceGroups.list_suggestions(context.admin)

    assert {:ok, %{status: "accepted"}} =
             ResourceGroups.accept_suggestion(context.admin, suggestion.id)

    assert [%{direct: true, trusted: true}] =
             ResourceGroups.list_resource_groups(context.admin, stg.id)

    assert [%{kind: "group_member_added", metadata: metadata} = event | _] =
             Inventory.list_change_events(context.admin, stg.id)

    assert event.actor_user_id == context.admin.user.id
    assert metadata["reason"] == "Suggested by the triage rule Staging hosts"

    assert RengaWeb.ChangeDescription.describe(event) ==
             "Added to Staging · Suggested by the triage rule Staging hosts"

    assert ResourceGroups.list_suggestions(context.admin) == []

    # Already decided.
    assert {:error, :not_found} = ResourceGroups.accept_suggestion(context.admin, suggestion.id)
  end

  test "people without inventory.edit cannot accept or dismiss", context do
    server_fixture(context.admin, "stg-01", hostname: "stg-01")
    {:ok, _result} = staging_rule(context)
    [suggestion] = ResourceGroups.list_suggestions(context.admin)

    assert {:error, :forbidden} = ResourceGroups.accept_suggestion(context.member, suggestion.id)
    assert {:error, :forbidden} = ResourceGroups.dismiss_suggestion(context.member, suggestion.id)
    assert Repo.all(Member) == []
    assert [%{status: "open"}] = ResourceGroups.list_suggestions(context.admin)
  end

  test "accepting goes through exclusivity like a manual add", context do
    {:ok, set} =
      ResourceGroups.create_group_set(context.admin, %{name: "Environment", exclusive: true})

    {:ok, prod} =
      ResourceGroups.create_group(context.admin, %{name: "Prod", group_set_id: set.id})

    {:ok, _staging} =
      ResourceGroups.update_group(context.admin, context.staging, %{group_set_id: set.id})

    stg = server_fixture(context.admin, "stg-01", hostname: "stg-01")
    {:ok, 1} = ResourceGroups.add_members(context.admin, prod, [stg.id])
    {:ok, _result} = staging_rule(context)
    [suggestion] = ResourceGroups.list_suggestions(context.admin)

    assert {:error, {:exclusive_conflict, _conflicts}} =
             ResourceGroups.accept_suggestion(context.admin, suggestion.id)

    assert [%{status: "open"}] = ResourceGroups.list_suggestions(context.admin)
  end

  test "a dismissed suggestion returns only after the rule changes", context do
    stg = server_fixture(context.admin, "stg-01", hostname: "stg-01")
    {:ok, %{rule: rule}} = staging_rule(context)
    [suggestion] = ResourceGroups.list_suggestions(context.admin)

    assert {:ok, %{status: "dismissed"}} =
             ResourceGroups.dismiss_suggestion(context.admin, suggestion.id)

    # Applying again, as a new report does, leaves it dismissed.
    assert {:ok, 0} = TriageRules.apply_to_resource(context.organization.id, stg.id)
    assert ResourceGroups.list_suggestions(context.admin) == []

    assert {:ok, %{applied: 1}} =
             TriageRules.update_rule(context.admin, rule, %{"name" => "Staging"})

    assert [%{rule_name: "Staging"}] = ResourceGroups.list_suggestions(context.admin)
  end

  test "rule versions advance past equal or backwards wall-clock time", context do
    stg = server_fixture(context.admin, "stg-01", hostname: "stg-01")
    {:ok, %{rule: rule}} = staging_rule(context)
    [suggestion] = ResourceGroups.list_suggestions(context.admin)
    future = DateTime.add(rule.updated_at, 60, :second)

    from(rule in Rule, where: rule.id == ^rule.id)
    |> Repo.update_all(set: [updated_at: future])

    from(suggestion in Suggestion, where: suggestion.id == ^suggestion.id)
    |> Repo.update_all(set: [rule_updated_at: future])

    assert {:ok, %{status: "dismissed"}} =
             ResourceGroups.dismiss_suggestion(context.admin, suggestion.id)

    rule = Repo.reload!(rule)

    assert {:ok, %{rule: updated, applied: 1}} =
             TriageRules.update_rule(context.admin, rule, %{"name" => "Staging"})

    assert DateTime.compare(updated.updated_at, future) == :gt
    assert [%{rule_name: "Staging"}] = ResourceGroups.list_suggestions(context.admin)

    [reopened] = ResourceGroups.list_suggestions(context.admin)

    assert {:ok, %{status: "dismissed"}} =
             ResourceGroups.dismiss_suggestion(context.admin, reopened.id)

    assert {:ok, %{rule: unchanged, applied: 0}} =
             TriageRules.update_rule(context.admin, updated, %{
               "name" => "Staging",
               "match_on" => "hostname"
             })

    assert unchanged.updated_at == updated.updated_at
    assert {:ok, 0} = TriageRules.apply_to_resource(context.organization.id, stg.id)
    assert ResourceGroups.list_suggestions(context.admin) == []
  end

  test "overlapping unchanged rules remember each dismissal", context do
    stg = server_fixture(context.admin, "stg-01", hostname: "stg-01")
    {:ok, %{applied: 1}} = staging_rule(context)

    assert {:ok, %{applied: 0}} =
             staging_rule(context, %{"name" => "Other staging hosts"})

    [suggestion] = ResourceGroups.list_suggestions(context.admin)

    assert {:ok, %{status: "dismissed"}} =
             ResourceGroups.dismiss_suggestion(context.admin, suggestion.id)

    assert {:ok, 1} = TriageRules.apply_to_resource(context.organization.id, stg.id)
    [reopened] = ResourceGroups.list_suggestions(context.admin)
    assert reopened.rule_name == "Other staging hosts"

    assert {:ok, %{status: "dismissed"}} =
             ResourceGroups.dismiss_suggestion(context.admin, reopened.id)

    assert {:ok, 0} = TriageRules.apply_to_resource(context.organization.id, stg.id)
    assert ResourceGroups.list_suggestions(context.admin) == []
  end

  test "a resource already in the group is not suggested", context do
    stg = server_fixture(context.admin, "stg-01", hostname: "stg-01")
    {:ok, 1} = ResourceGroups.add_members(context.admin, context.staging, [stg.id])

    assert {:ok, %{applied: 0}} = staging_rule(context)
    assert ResourceGroups.list_suggestions(context.admin) == []
  end
end
