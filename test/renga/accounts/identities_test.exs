defmodule Renga.Accounts.IdentitiesTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures

  alias Renga.Accounts
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.UserIdentity
  alias Renga.FakeOIDCProvider
  alias Renga.Repo

  setup do
    fake = FakeOIDCProvider.new()
    %{fake: fake, provider: identity_provider_fixture(fake)}
  end

  defp result(provider, claims) do
    %{
      provider: provider,
      revision: IdentityProviders.active_revision(provider),
      claims:
        Map.merge(
          %{"sub" => "subject-1", "email" => "sam@example.com", "email_verified" => true},
          claims
        )
    }
  end

  defp rechecked(user) do
    user = set_password(user)
    token = Accounts.generate_user_session_token(user)
    :ok = Accounts.recheck_with_password(user, token, valid_user_password())
    {user, token}
  end

  describe "link/2" do
    test "links the provider subject to the account", %{provider: provider} do
      user = user_fixture()

      assert {:ok, identity} = Accounts.link_identity(user, result(provider, %{}))
      assert identity.user_id == user.id
      assert identity.subject == "subject-1"
      assert identity.email == "sam@example.com"

      assert [%{kind: "identity_linked", metadata: %{"provider" => id}} | _] =
               Accounts.list_security_events(user)

      assert id == provider.id
      assert_received {:email, %Swoosh.Email{subject: "Security notice from Renga"}}
    end

    test "links regardless of the account's own email", %{provider: provider} do
      user = user_fixture(%{email: "someone-else@example.com"})

      assert {:ok, _identity} =
               Accounts.link_identity(user, result(provider, %{"email_verified" => false}))
    end

    test "refuses a subject already linked to this account", %{provider: provider} do
      user = user_fixture()
      {:ok, _identity} = Accounts.link_identity(user, result(provider, %{}))

      assert {:error, :already_linked} = Accounts.link_identity(user, result(provider, %{}))
    end

    test "refuses a subject linked to another account", %{provider: provider} do
      {:ok, _identity} = Accounts.link_identity(user_fixture(), result(provider, %{}))
      user = user_fixture()

      assert {:error, :linked_elsewhere} = Accounts.link_identity(user, result(provider, %{}))
      assert Accounts.list_user_identities(user) == []
    end

    test "applies the provider's email domain allowlist", %{fake: fake} do
      provider = identity_provider_fixture(fake, %{"email_domains" => ["corp.example"]})
      user = user_fixture()

      assert {:error, :domain_not_allowed} = Accounts.link_identity(user, result(provider, %{}))

      assert {:error, :domain_not_allowed} =
               Accounts.link_identity(
                 user,
                 result(provider, %{"email" => "sam@corp.example", "email_verified" => false})
               )

      assert {:ok, _identity} =
               Accounts.link_identity(user, result(provider, %{"email" => "sam@corp.example"}))
    end

    test "refuses claims without a subject", %{provider: provider} do
      assert {:error, :invalid_claims} =
               Accounts.link_identity(user_fixture(), result(provider, %{"sub" => ""}))
    end

    test "refuses when the provider changed or was disabled", %{provider: provider} do
      user = user_fixture()
      stale = result(provider, %{})

      provider |> Ecto.Changeset.change(active_revision: 2) |> Repo.update!()
      assert {:error, :provider_changed} = Accounts.link_identity(user, stale)

      provider |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
      assert {:error, :inactive} = Accounts.link_identity(user, stale)
      assert Accounts.list_user_identities(user) == []
    end
  end

  describe "unlink/3" do
    test "unlinks after the re-check", %{provider: provider} do
      {user, token} = rechecked(user_fixture())
      {:ok, identity} = Accounts.link_identity(user, result(provider, %{}))

      assert {:ok, unlinked} = Accounts.unlink_identity(user, token, identity.id)
      assert unlinked.provider.id == provider.id
      refute Repo.get(UserIdentity, identity.id)

      assert [%{kind: "identity_unlinked"} | _] = Accounts.list_security_events(user)
    end

    test "requires the re-check", %{provider: provider} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      {:ok, identity} = Accounts.link_identity(user, result(provider, %{}))

      assert {:error, :recheck_required} = Accounts.unlink_identity(user, token, identity.id)
      assert Repo.get(UserIdentity, identity.id)
    end

    test "only unlinks the account's own identities", %{provider: provider} do
      {:ok, identity} = Accounts.link_identity(user_fixture(), result(provider, %{}))
      {user, token} = rechecked(user_fixture())

      assert {:error, :not_found} = Accounts.unlink_identity(user, token, identity.id)
      assert {:error, :not_found} = Accounts.unlink_identity(user, token, "not-an-id")
      assert Repo.get(UserIdentity, identity.id)
    end
  end

  describe "linkable_providers/1" do
    test "offers usable, shown providers the account has not linked", %{
      fake: fake,
      provider: provider
    } do
      hidden = identity_provider_fixture(fake, %{"hidden" => true})
      user = user_fixture()

      assert Enum.map(Accounts.linkable_providers(user), & &1.id) == [provider.id]
      refute hidden.id in Enum.map(Accounts.linkable_providers(user), & &1.id)

      {:ok, _identity} = Accounts.link_identity(user, result(provider, %{}))
      assert Accounts.linkable_providers(user) == []
    end
  end
end
