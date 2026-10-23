defmodule Renga.Scim.LinkingTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]
  import Renga.ScimFixtures

  alias Renga.Accounts.Identities
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.UserIdentity
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Scim
  alias Renga.Scim.Client
  alias Renga.Scim.DirectoryUser
  alias Renga.Scim.Linking
  alias Renga.Scim.Users

  setup do
    owner = member_scope(organization_fixture(), "owner")
    provider = scim_provider_fixture(%{"allow_sign_up" => false})
    connection = scim_connection_fixture(owner, %{"provider_id" => provider.id})
    {token, _value} = scim_token_fixture(owner, connection)
    client = %Client{connection: connection, token_id: token.id}

    %{owner: owner, provider: provider, connection: connection, client: client}
  end

  defp entry!(client, attrs) do
    {:ok, entry} = Users.create(client, Map.merge(%{"userName" => "sam@example.com"}, attrs))
    entry
  end

  defp sign_in(provider, claims) do
    Identities.resolve(%{
      provider: provider,
      revision: IdentityProviders.revision(provider, 1),
      claims: Map.merge(%{"email" => "sam@example.com", "email_verified" => true}, claims)
    })
  end

  defp identity!(user, provider, subject) do
    Repo.insert!(%UserIdentity{user_id: user.id, provider_id: provider.id, subject: subject})
  end

  test "a returning sign-in links the entry whose externalId is its sub", context do
    entry = entry!(context.client, %{"externalId" => "sub-1"})
    other = entry!(context.client, %{"userName" => "kim", "externalId" => "sub-2"})
    user = user_fixture()
    identity = identity!(user, context.provider, "sub-1")

    assert {:ok, %{id: user_id}} = sign_in(context.provider, %{"sub" => "sub-1"})
    assert user_id == user.id

    assert Repo.reload!(entry).user_identity_id == identity.id
    assert Repo.reload!(other).user_identity_id == nil

    assert %ChangeEvent{metadata: %{"scim_user_id" => entry_id}} =
             Repo.get_by!(ChangeEvent, kind: "scim_user_linked")

    assert entry_id == entry.id
  end

  test "an active entry opens sign-up and links the new account", context do
    entry = entry!(context.client, %{"externalId" => "sub-new"})

    assert {:ok, user} =
             sign_in(context.provider, %{"sub" => "sub-new", "email" => "new@example.com"})

    assert user.email == "new@example.com"

    identity = Repo.get_by!(UserIdentity, provider_id: context.provider.id, subject: "sub-new")
    assert Repo.reload!(entry).user_identity_id == identity.id
  end

  test "sign-up stays closed without an active, unlinked, correlating entry", context do
    entry!(context.client, %{"externalId" => "inactive", "active" => false})
    assert {:error, :sign_up_closed} = sign_in(context.provider, %{"sub" => "inactive"})
    assert {:error, :sign_up_closed} = sign_in(context.provider, %{"sub" => "nobody"})

    # An email match is not correlation.
    entry!(context.client, %{"userName" => "x", "externalId" => "other-sub"})
    assert {:error, :sign_up_closed} = sign_in(context.provider, %{"sub" => "sam@example.com"})
  end

  test "keeps RFD 15's email collision refusal", context do
    user_fixture(%{email: "taken@example.com"})
    entry!(context.client, %{"externalId" => "sub-3"})

    assert {:error, :email_in_use} =
             sign_in(context.provider, %{"sub" => "sub-3", "email" => "taken@example.com"})
  end

  test "never reassigns an entry bound to another identity", context do
    entry = entry!(context.client, %{"externalId" => "sub-1"})
    first = identity!(user_fixture(), context.provider, "sub-1")
    assert [_linked] = Linking.link_identity(first, %{"sub" => "sub-1"})

    second = identity!(user_fixture(), scim_provider_fixture(), "sub-1")
    second = %{second | provider_id: context.provider.id}

    assert [] = Linking.link_identity(second, %{"sub" => "sub-1"})
    assert Repo.reload!(entry).user_identity_id == first.id
    assert Repo.get_by!(ChangeEvent, kind: "scim_link_refused")
  end

  test "links nothing through a disabled connection or another provider", context do
    entry = entry!(context.client, %{"externalId" => "sub-1"})
    other_provider = scim_provider_fixture()
    identity!(user_fixture(), other_provider, "sub-1")

    assert {:ok, _user} = sign_in(other_provider, %{"sub" => "sub-1"})
    assert Repo.reload!(entry).user_identity_id == nil

    {:ok, _} = Scim.disable_connection(context.owner, context.connection.id)
    identity!(user_fixture(), context.provider, "sub-1")
    assert {:ok, _user} = sign_in(context.provider, %{"sub" => "sub-1"})
    assert Repo.reload!(entry).user_identity_id == nil
  end

  test "rejects unusable correlation values" do
    refute Linking.correlation_value?(nil)
    refute Linking.correlation_value?("")
    refute Linking.correlation_value?(["sub-1"])
    refute Linking.correlation_value?(123)
    refute Linking.correlation_value?("sub\n1")
    refute Linking.correlation_value?(String.duplicate("a", 256))
    assert Linking.correlation_value?("00u1abc")
  end

  test "an entry with no externalId never links", context do
    entry = entry!(context.client, %{})
    identity = identity!(user_fixture(), context.provider, "sub-1")

    assert [] = Linking.link_identity(identity, %{"sub" => ""})
    assert [] = Linking.link_identity(identity, %{"sub" => nil})
    assert Repo.reload!(entry).user_identity_id == nil
    assert DirectoryUser |> Repo.all() |> Enum.all?(&is_nil(&1.user_identity_id))
  end
end
