defmodule Renga.SavedViewsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.SavedViews

  setup do
    organization = organization_fixture()

    scopes =
      for role <- ["admin", "member"], into: %{} do
        user = user_fixture()
        organization_membership_fixture(user, organization, %{role: role})
        {role, Renga.Accounts.scope_for_user(user, organization.id)}
      end

    %{organization: organization, admin: scopes["admin"], member: scopes["member"]}
  end

  defp view_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "name" => "Stale servers",
      "area" => "inventory",
      "params" => %{"kind" => "server", "freshness" => "stale"}
    })
  end

  test "members save personal views that only they see", %{admin: admin, member: member} do
    assert {:ok, view} = SavedViews.create_view(member, view_attrs())
    assert view.user_id == member.user.id
    assert view.created_by_id == member.user.id

    assert [%{id: id}] = SavedViews.list_views(member, "inventory")
    assert id == view.id
    assert SavedViews.list_views(admin, "inventory") == []
    assert_raise Ecto.NoResultsError, fn -> SavedViews.get_view!(admin, view.id) end
  end

  test "only owners and admins share views with the organization", %{admin: admin, member: member} do
    assert {:error, :forbidden} =
             SavedViews.create_view(member, view_attrs(%{"shared" => "true"}))

    assert {:ok, view} = SavedViews.create_view(admin, view_attrs(%{"shared" => "true"}))
    assert is_nil(view.user_id)
    assert [_shared] = SavedViews.list_views(member, "inventory")

    refute SavedViews.can_manage?(member, view)
    assert {:error, :forbidden} = SavedViews.update_view(member, view, %{"pinned" => true})
    assert {:error, :forbidden} = SavedViews.delete_view(member, view)
  end

  test "a demoted admin can no longer change organization views", %{organization: organization} do
    user = user_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    stale_scope = Renga.Accounts.scope_for_user(user, organization.id)
    {:ok, view} = SavedViews.create_view(stale_scope, view_attrs(%{"shared" => "true"}))

    {:ok, _membership} =
      Renga.Accounts.update_organization_membership(membership, %{role: "member"})

    assert {:error, :forbidden} = SavedViews.delete_view(stale_scope, view)
  end

  test "the sidebar shows pinned views: the organization's, then the person's", %{
    admin: admin,
    member: member
  } do
    {:ok, _} =
      SavedViews.create_view(
        admin,
        view_attrs(%{"name" => "Org pinned", "shared" => "true", "pinned" => "true"})
      )

    {:ok, _} =
      SavedViews.create_view(admin, view_attrs(%{"name" => "Org quiet", "shared" => "true"}))

    {:ok, _} =
      SavedViews.create_view(member, view_attrs(%{"name" => "Mine pinned", "pinned" => "true"}))

    {:ok, _} =
      SavedViews.create_view(admin, view_attrs(%{"name" => "Admin's own", "pinned" => "true"}))

    assert member |> SavedViews.list_sidebar_views() |> Enum.map(& &1.name) == [
             "Org pinned",
             "Mine pinned"
           ]
  end

  test "names are unique per person and per organization, ignoring case", %{
    admin: admin,
    member: member
  } do
    {:ok, _} = SavedViews.create_view(member, view_attrs())

    assert {:error, changeset} =
             SavedViews.create_view(member, view_attrs(%{"name" => "stale SERVERS"}))

    assert "you already have a view with this name" in errors_on(changeset).name

    # Another person, or the organization, may use the same name.
    assert {:ok, _} = SavedViews.create_view(admin, view_attrs())
    assert {:ok, _} = SavedViews.create_view(admin, view_attrs(%{"shared" => "true"}))
  end

  test "params must be a small map of strings", %{member: member} do
    assert {:error, changeset} =
             SavedViews.create_view(member, view_attrs(%{"params" => %{"kind" => ["server"]}}))

    assert "must be a short list query" in errors_on(changeset).params
  end

  test "views never cross organizations", %{admin: admin} do
    other = organization_fixture()
    outsider = user_fixture()
    organization_membership_fixture(outsider, other, %{role: "owner"})
    outsider_scope = Renga.Accounts.scope_for_user(outsider, other.id)

    {:ok, view} = SavedViews.create_view(admin, view_attrs(%{"shared" => "true"}))

    assert SavedViews.list_views(outsider_scope, "inventory") == []
    assert {:error, :forbidden} = SavedViews.delete_view(outsider_scope, view)
  end
end
