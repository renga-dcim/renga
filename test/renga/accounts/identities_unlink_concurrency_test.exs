defmodule Renga.Accounts.IdentitiesUnlinkConcurrencyTest do
  @moduledoc """
  Unlinking an identity gives up the SCIM grants it carried (RFD 16) even
  when a sign-in through that identity links a directory entry at the same
  time.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.MutationRace, only: [race: 2]
  import Renga.ScimFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Accounts.Identities
  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderEvent
  alias Renga.Accounts.IdentityProviderRevision
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Accounts.UserIdentity
  alias Renga.Repo
  alias Renga.Scim.Client
  alias Renga.Scim.DirectoryUser
  alias Renga.Scim.Users

  test "a sign-in that links an entry while the identity is unlinked leaves no grant" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    organization = organization_fixture()
    owner = member_scope(organization, "owner")
    provider = scim_provider_fixture(%{"allow_sign_up" => false})

    connection =
      scim_connection_fixture(owner, %{"provider_id" => provider.id, "default_role" => "member"})

    {token, _value} = scim_token_fixture(owner, connection)

    {:ok, entry} =
      Users.create(%Client{connection: connection, token_id: token.id}, %{
        "userName" => "sam@example.com",
        "externalId" => "sub-1"
      })

    user = set_password(user_fixture())

    identity =
      Repo.insert!(%UserIdentity{user_id: user.id, provider_id: provider.id, subject: "sub-1"})

    session = Accounts.generate_user_session_token(user)
    :ok = Accounts.recheck_with_password(user, session, valid_user_password())

    try do
      # The sign-in links the entry and grants a membership, and holds its
      # transaction open while the unlink starts.
      assert {{:ok, %User{}}, {:ok, %UserIdentity{}}} =
               race(
                 fn ->
                   Identities.resolve(%{
                     provider: provider,
                     revision: IdentityProviders.revision(provider, 1),
                     claims: %{"sub" => "sub-1", "email" => "sam@example.com"}
                   })
                 end,
                 fn -> Accounts.unlink_identity(user, session, identity.id) end
               )

      refute Repo.get(UserIdentity, identity.id)
      assert Repo.reload!(entry).user_identity_id == nil

      assert %OrganizationMembership{status: "disabled"} =
               Repo.get_by!(OrganizationMembership,
                 organization_id: organization.id,
                 user_id: user.id
               )
    after
      # Only what this test committed outside the sandbox.
      Repo.delete_all(where(DirectoryUser, connection_id: ^connection.id))
      Repo.delete!(organization)
      Repo.delete_all(where(User, [u], u.id in ^[user.id, owner.user.id]))
      Repo.delete_all(where(IdentityProviderEvent, provider_id: ^provider.id))
      Repo.delete_all(where(IdentityProviderRevision, provider_id: ^provider.id))
      Repo.delete_all(where(IdentityProvider, id: ^provider.id))
      Sandbox.checkin(Repo)
    end
  end
end
