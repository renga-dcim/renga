defmodule RengaWeb.InboxGroupSuggestionsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Inventory
  alias Renga.ResourceGroups
  alias Renga.TriageRules

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = member(organization, "admin")
    {member_conn, _member} = member(organization, "member")

    {:ok, staging} = ResourceGroups.create_group(admin, %{name: "Staging"})
    stg = server!(admin, "stg-01")
    other = server!(admin, "stg-02")

    {:ok, _result} =
      TriageRules.create_rule(admin, %{
        "kind" => "group",
        "name" => "Staging hosts",
        "hostname_pattern" => "stg-*",
        "resource_group_id" => staging.id
      })

    [first, second] = ResourceGroups.list_suggestions(admin)

    %{
      admin_conn: admin_conn,
      member_conn: member_conn,
      admin: admin,
      staging: staging,
      stg: stg,
      other: other,
      first: first,
      second: second
    }
  end

  test "suggestions lead the Triage tab, and accepting adds the resource", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox?group=triage")

    assert has_element?(view, "#group-suggestions-title", "2")

    assert has_element?(
             view,
             "#group-suggestion-#{context.first.id}",
             "Suggested by Staging hosts"
           )

    view |> element("#group-suggestion-#{context.first.id}-accept") |> render_click()

    assert render(view) =~ "Added to the group"
    refute has_element?(view, "#group-suggestion-#{context.first.id}")

    assert [%{direct: true}] =
             ResourceGroups.list_resource_groups(context.admin, context.first.resource_id)
  end

  test "dismissing leaves membership alone", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox?group=triage")

    view |> element("#group-suggestion-#{context.second.id}-dismiss") |> render_click()

    assert render(view) =~ "Suggestion dismissed"
    refute has_element?(view, "#group-suggestion-#{context.second.id}")
    assert ResourceGroups.list_resource_groups(context.admin, context.second.resource_id) == []
  end

  test "people without inventory.edit read suggestions without deciding", context do
    # Without groups.manage, a group is visible once it has a trusted member.
    {:ok, view, _html} = live(context.member_conn, ~p"/inbox?group=triage")
    refute has_element?(view, "#group-suggestions")

    {:ok, 1} =
      ResourceGroups.add_members(context.admin, context.staging, [
        server!(context.admin, "app-01").id
      ])

    {:ok, view, _html} = live(context.member_conn, ~p"/inbox?group=triage")

    assert has_element?(view, "#group-suggestion-#{context.first.id}")
    refute has_element?(view, "#group-suggestion-#{context.first.id}-accept")

    # A forged event is refused by the context.
    render_click(view, "accept_suggestion", %{"id" => context.first.id})

    assert render(view) =~ "requires the owner or admin role"
    assert ResourceGroups.list_resource_groups(context.admin, context.first.resource_id) == []
  end

  test "a suggestion decided elsewhere says so", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox?group=triage")
    {:ok, _dismissed} = ResourceGroups.dismiss_suggestion(context.admin, context.first.id)

    view |> element("#group-suggestion-#{context.first.id}-accept") |> render_click()

    assert render(view) =~ "Someone already decided that suggestion"
    refute has_element?(view, "#group-suggestion-#{context.first.id}")
  end

  test "malformed decision events leave the view usable and membership unchanged", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox?group=triage")

    render_click(view, "accept_suggestion", %{})
    assert has_element?(view, "#group-suggestions-title", "2")
    assert render(view) =~ "Someone already decided that suggestion"

    render_click(view, "dismiss_suggestion", %{})
    assert has_element?(view, "#group-suggestions-title", "2")
    assert ResourceGroups.list_resource_groups(context.admin, context.first.resource_id) == []
  end

  test "show more reaches every suggestion and decisions refill the first page", context do
    {:ok, 1} =
      ResourceGroups.add_members(context.admin, context.staging, [
        server!(context.admin, "app-visible").id
      ])

    added =
      for number <- 3..21 do
        resource = server!(context.admin, "stg-#{number}")

        assert {:ok, 1} =
                 TriageRules.apply_to_resource(context.admin.organization_id, resource.id)

        resource
      end

    suggestions = ResourceGroups.list_suggestions(context.admin)
    assert length(suggestions) == 21
    last = List.last(suggestions)

    {:ok, reader, _html} =
      live(context.member_conn, ~p"/inbox?group=triage&missing=identity")

    assert has_element?(reader, "#triage", "Nothing is missing facts")
    assert has_element?(reader, "#group-suggestions-more", "1 more")
    refute has_element?(reader, "#group-suggestion-#{last.id}")

    reader |> element("#group-suggestions-show-more") |> render_click()
    assert has_element?(reader, "#group-suggestion-#{last.id}")
    refute has_element?(reader, "#group-suggestions-show-more")

    {:ok, editor, _html} = live(context.admin_conn, ~p"/inbox?group=triage&missing=identity")
    refute has_element?(editor, "#group-suggestion-#{last.id}")

    editor |> element("#group-suggestion-#{context.first.id}-dismiss") |> render_click()

    assert has_element?(editor, "#group-suggestion-#{last.id}")
    assert has_element?(editor, "#group-suggestions-title", "20")
    assert Enum.any?(added, &(&1.id == last.resource_id))
  end

  defp server!(scope, name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: "server", name: name, lifecycle_state: "active"})

    {:ok, _host} = Inventory.create_host(scope, resource.id, %{hostname: name})
    resource
  end

  defp member(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Renga.Accounts.scope_for_user(user, organization.id)}
  end
end
