defmodule Renga.Accounts.IdentitiesPolicyTest do
  # Changes the application's sign-in settings.
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures

  alias Renga.Accounts
  alias Renga.Accounts.IdentityProviders
  alias Renga.FakeOIDCProvider

  setup do
    on_exit(fn -> Application.delete_env(:renga, :local_sign_in) end)

    fake = FakeOIDCProvider.new()
    provider = identity_provider_fixture(fake)

    user = set_password(user_fixture())
    token = Accounts.generate_user_session_token(user)
    :ok = Accounts.recheck_with_password(user, token, valid_user_password())

    %{fake: fake, provider: provider, user: user, token: token}
  end

  defp link(user, provider, subject) do
    {:ok, identity} =
      Accounts.link_identity(user, %{
        provider: provider,
        revision: IdentityProviders.active_revision(provider),
        claims: %{"sub" => subject}
      })

    identity
  end

  test "with local sign-in disabled, keeps the last usable identity", %{
    fake: fake,
    provider: provider,
    user: user,
    token: token
  } do
    identity = link(user, provider, "subject-1")
    Application.put_env(:renga, :local_sign_in, :disabled)

    assert {:error, :last_sign_in_method} = Accounts.unlink_identity(user, token, identity.id)

    # An identity at a disabled provider does not sign anyone in.
    other = identity_provider_fixture(fake)
    other_identity = link(user, other, "subject-2")
    {:ok, _} = IdentityProviders.disable(other, {:operator, "test"})

    assert {:error, :last_sign_in_method} = Accounts.unlink_identity(user, token, identity.id)

    {:ok, _} = IdentityProviders.enable(other, {:operator, "test"})
    assert {:ok, _} = Accounts.unlink_identity(user, token, identity.id)

    assert {:error, :last_sign_in_method} =
             Accounts.unlink_identity(user, token, other_identity.id)
  end

  test "with local sign-in enabled, the account's email still signs it in", %{
    provider: provider,
    user: user,
    token: token
  } do
    identity = link(user, provider, "subject-1")
    assert {:ok, _} = Accounts.unlink_identity(user, token, identity.id)
  end
end
