defmodule Renga.Scim.GrantsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Accounts.UserIdentity
  alias Renga.Inventory.ChangeEvent
  alias Renga.Members
  alias Renga.Repo
  alias Renga.Scim
  alias Renga.Scim.Client
  alias Renga.Scim.DirectoryUser
  alias Renga.Scim.Groups
  alias Renga.Scim.Linking
  alias Renga.Scim.Users

  setup do
    organization = organization_fixture()
    owner = member_scope(organization, "owner")
    provider = scim_provider_fixture()

    connection =
      scim_connection_fixture(owner, %{"provider_id" => provider.id, "default_role" => "member"})

    {token, _value} = scim_token_fixture(owner, connection)

    %{
      organization: organization,
      owner: owner,
      provider: provider,
      connection: connection,
      client: %Client{connection: connection, token_id: token.id, request_id: "req-1"}
    }
  end

  # A provisioned entry linked to a new account, as a sign-in links it.
  defp linked!(context, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    attrs = Map.merge(%{"userName" => "user#{n}", "externalId" => "sub-#{n}"}, attrs)
    {:ok, entry} = Users.create(context.client, attrs)
    user = user_fixture()

    identity =
      Repo.insert!(%UserIdentity{
        user_id: user.id,
        provider_id: context.provider.id,
        subject: attrs["externalId"]
      })

    [_linked] = Linking.link_identity(identity, %{"sub" => attrs["externalId"]})
    {Repo.reload!(entry), user}
  end

  defp membership(context, user),
    do:
      Repo.get_by(OrganizationMembership,
        organization_id: context.organization.id,
        user_id: user.id
      )

  defp access(context, user) do
    case membership(context, user) do
      %{status: "active", role: role} -> role
      _none_or_disabled -> nil
    end
  end

  defp patch!(context, entry, operations) do
    {:ok, _entry} = Users.patch(context.client, entry.id, operations)
  end

  defp group!(context, members, role \\ nil) do
    {:ok, group} =
      Groups.create(context.client, %{
        "displayName" => "Group #{System.unique_integer([:positive])}",
        "members" => Enum.map(members, &%{"value" => &1.id})
      })

    if role, do: {:ok, _} = Scim.map_group(context.owner, group.id, role)
    group
  end

  test "a linked, active entry gets the default role as a SCIM grant", context do
    {_entry, user} = linked!(context)

    membership = membership(context, user)
    assert membership.role == "member" and membership.status == "active"
    assert membership.scim_connection_id == context.connection.id

    event = Repo.get_by!(ChangeEvent, kind: "scim_grant_added")
    assert event.metadata["membership_id"] == membership.id
    assert event.metadata["connection_id"] == context.connection.id
  end

  test "an unlinked entry grants nothing, and neither does no role", context do
    {:ok, _unlinked} =
      Users.create(context.client, %{"userName" => "x", "externalId" => "nobody"})

    assert Repo.aggregate(
             where(OrganizationMembership, [m], not is_nil(m.scim_connection_id)),
             :count
           ) == 0

    {:ok, _} = Scim.update_default_role(context.owner, context.connection.id, nil)
    {_entry, user} = linked!(context)
    assert membership(context, user) == nil
  end

  test "the highest of the default role and mapped groups wins, and leaving one downgrades",
       context do
    {entry, user} = linked!(context)
    admins = group!(context, [entry], "admin")
    viewers = group!(context, [entry], "viewer")
    assert access(context, user) == "admin"

    {:ok, _} =
      Groups.patch(context.client, admins.id, [
        %{"op" => "remove", "path" => ~s(members[value eq "#{entry.id}"])}
      ])

    assert access(context, user) == "member"

    {:ok, _} = Scim.update_default_role(context.owner, context.connection.id, nil)
    assert access(context, user) == "viewer"

    {:ok, _} = Groups.delete(context.client, viewers.id)
    assert access(context, user) == nil
    assert membership(context, user).status == "disabled"
  end

  test "mappings follow the group's id, not its name", context do
    {entry, user} = linked!(context)
    group = group!(context, [entry], "owner")
    assert access(context, user) == "owner"

    {:ok, _} =
      Groups.patch(context.client, group.id, [
        %{"op" => "replace", "path" => "displayName", "value" => "Renamed"}
      ])

    assert access(context, user) == "owner"

    {:ok, _} = Groups.delete(context.client, group.id)
    assert access(context, user) == "member"

    {:ok, recreated} =
      Groups.create(context.client, %{
        "displayName" => "Renamed",
        "members" => [%{"value" => entry.id}]
      })

    assert recreated.role == nil
    assert access(context, user) == "member"
  end

  test "Entra's \"False\" removes the grant and \"True\" restores it", context do
    {entry, user} = linked!(context)

    patch!(context, entry, [%{"op" => "Replace", "path" => "active", "value" => "False"}])
    assert membership(context, user).status == "disabled"

    event = Repo.get_by!(ChangeEvent, kind: "scim_grant_removed")
    assert event.metadata["token_id"] == context.client.token_id
    assert event.metadata["request_id"] == "req-1"

    patch!(context, entry, [%{"op" => "Replace", "path" => "active", "value" => "True"}])
    assert access(context, user) == "member"
  end

  test "deleting the entry or changing its externalId removes the grant", context do
    {entry, user} = linked!(context)
    patch!(context, entry, [%{"op" => "replace", "path" => "externalId", "value" => "changed"}])
    assert Repo.reload!(entry).user_identity_id == nil
    assert access(context, user) == nil

    {other, other_user} = linked!(context)
    {:ok, _} = Users.delete(context.client, other.id)
    assert access(context, other_user) == nil
    assert Repo.get(User, other_user.id), "the account stays"
  end

  test "a membership granted by hand is never changed", context do
    user = user_fixture()
    organization_membership_fixture(user, context.organization, %{role: "viewer"})

    {:ok, entry} =
      Users.create(context.client, %{"userName" => "manual", "externalId" => "sub-m"})

    identity =
      Repo.insert!(%UserIdentity{
        user_id: user.id,
        provider_id: context.provider.id,
        subject: "sub-m"
      })

    Linking.link_identity(identity, %{"sub" => "sub-m"})

    group!(context, [entry], "owner")
    assert %{role: "viewer", scim_connection_id: nil} = membership(context, user)

    patch!(context, entry, [%{"op" => "replace", "path" => "active", "value" => false}])
    assert %{role: "viewer", status: "active"} = membership(context, user)

    # Manual authority wins in both directions: SCIM cannot elevate a manual
    # viewer or reactivate a manually disabled member, even on a fresh sign-in.
    assert Renga.Accounts.scope_for_user(user, context.organization.id).roles == ["viewer"]
    {:ok, _} = Members.disable_member(context.owner, membership(context, user).id)
    patch!(context, entry, [%{"op" => "replace", "path" => "active", "value" => true}])
    Linking.link_identity(identity, %{"sub" => "sub-m"})

    assert %{role: "viewer", status: "disabled", scim_connection_id: nil} =
             membership(context, user)

    assert Renga.Accounts.scope_for_user(user, context.organization.id).organization_id == nil
  end

  test "supplemental manual assignments cannot keep a revoked SCIM membership alive", context do
    {entry, user} = linked!(context)
    managed = membership(context, user)

    {:ok, _} = Renga.Assignments.assign(context.owner, managed.id, %{"role" => "admin"})
    stale_scope = Renga.Accounts.scope_for_user(user, context.organization.id)
    assert {:ok, _} = Renga.Teams.create_team(stale_scope, %{name: "Before revocation"})

    patch!(context, entry, [%{"op" => "replace", "path" => "active", "value" => false}])

    assert Renga.Accounts.scope_for_user(user, context.organization.id).organization_id == nil
    assert Renga.Authorization.held_now(stale_scope, ["inventory.read", "teams.manage"]) == []

    assert {:error, :forbidden} =
             Renga.Teams.create_team(stale_scope, %{name: "After revocation"})

    # Valid correlation evidence alone cannot undo the directory's decision.
    identity = Repo.get!(UserIdentity, Repo.reload!(entry).user_identity_id)
    Linking.link_identity(identity, %{"sub" => entry.external_id})
    assert access(context, user) == nil
  end

  test "disabling the connection or its provider removes grants until re-enabled", context do
    {_entry, user} = linked!(context)

    {:ok, _} = Scim.disable_connection(context.owner, context.connection.id)
    assert access(context, user) == nil
    {:ok, _} = Scim.enable_connection(context.owner, context.connection.id)
    assert access(context, user) == "member"

    {:ok, _} = IdentityProviders.disable(context.provider, {:operator, "test"})
    assert access(context, user) == nil
    {:ok, _} = IdentityProviders.enable(context.provider, {:operator, "test"})
    assert access(context, user) == "member"
  end

  test "removing the provider disables the connection and clears bindings", context do
    {entry, user} = linked!(context)

    {:ok, _} = IdentityProviders.remove(context.provider, {:operator, "test"})

    assert access(context, user) == nil
    assert Repo.reload!(entry).user_identity_id == nil
    refute Scim.enabled_connection?(context.organization.id)
  end

  test "SCIM never changes the account's email, name, or other memberships", context do
    {entry, user} = linked!(context)
    other_org = organization_fixture()
    organization_membership_fixture(user, other_org, %{role: "admin"})

    patch!(context, entry, [
      %{"op" => "replace", "path" => "emails", "value" => [%{"value" => "new@example.com"}]},
      %{"op" => "replace", "path" => "active", "value" => false}
    ])

    {:ok, _} = Users.delete(context.client, entry.id)

    assert Repo.reload!(user).email == user.email

    assert %{role: "admin", status: "active"} =
             Repo.get_by(OrganizationMembership, organization_id: other_org.id, user_id: user.id)
  end

  test "admins cannot change a SCIM grant, and SCIM owners are not the recovery owner", context do
    {entry, user} = linked!(context)
    group!(context, [entry], "owner")
    managed = membership(context, user)

    assert {:error, :scim_managed} = Members.change_role(context.owner, managed.id, "viewer")
    assert {:error, :scim_managed} = Members.disable_member(context.owner, managed.id)

    own = Repo.get!(OrganizationMembership, context.owner.membership_id)
    assert {:error, :last_owner} = Members.change_role(context.owner, own.id, "admin")
  end

  test "only owners map groups, and only to built-in roles", context do
    group = group!(context, [])
    admin = member_scope(context.organization, "admin")

    assert {:error, :forbidden} = Scim.map_group(admin, group.id, "admin")
    assert {:error, :invalid_role} = Scim.map_group(context.owner, group.id, "root")
    assert {:ok, %{role: "admin"}} = Scim.map_group(context.owner, group.id, "admin")
    assert {:ok, %{role: nil}} = Scim.map_group(context.owner, group.id, "")

    assert ChangeEvent
           |> where(kind: "scim_group_mapped", actor_user_id: ^context.owner.user.id)
           |> Repo.aggregate(:count) == 2
  end

  test "a sign-in that links an entry grants at once", context do
    {:ok, entry} = Users.create(context.client, %{"userName" => "s", "externalId" => "sub-s"})

    {:ok, user} =
      Renga.Accounts.Identities.resolve(%{
        provider: context.provider,
        revision: IdentityProviders.revision(context.provider, 1),
        claims: %{"sub" => "sub-s", "email" => "s@example.com", "email_verified" => true}
      })

    assert Repo.reload!(entry).user_identity_id
    assert access(context, user) == "member"
    assert DirectoryUser |> Repo.get!(entry.id) |> Map.fetch!(:active)
  end
end
