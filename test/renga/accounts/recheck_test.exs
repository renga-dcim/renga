defmodule Renga.Accounts.RecheckTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures

  alias Renga.Accounts
  alias Renga.Accounts.AccountAuthorization
  alias Renga.Accounts.AccountChallenge
  alias Renga.Accounts.MFA
  alias Renga.Accounts.Recheck

  defp session_token(user), do: Accounts.generate_user_session_token(user)

  defp bootstrap_code(user, token) do
    {:ok, email} = Recheck.deliver_bootstrap_code(user, token)
    [code] = Regex.run(~r/[A-Z0-9]{5}-[A-Z0-9]{5}/, email.text_body)
    code
  end

  describe "methods/1" do
    test "a password is a re-check method" do
      assert Recheck.methods(set_password(user_fixture())) == [:password]
    end

    test "an account with neither a password nor a factor has none" do
      assert Recheck.methods(user_fixture()) == []
    end

    test "an account with an authenticator app confirms with it, not its password" do
      user = set_password(user_fixture())
      secret = MFA.new_totp_secret()
      {:ok, _codes} = MFA.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      assert Recheck.methods(user) == [:totp]

      assert {:error, :not_available} =
               Recheck.recheck_with_password(user, session_token(user), valid_user_password())
    end
  end

  describe "recheck_with_totp/3" do
    setup do
      user = user_fixture()
      secret = MFA.new_totp_secret()
      time = System.os_time(:second) - 30

      {:ok, _codes} =
        MFA.enable_totp(user, secret, NimbleTOTP.verification_code(secret, time: time))

      %{user: user, secret: secret, token: session_token(user)}
    end

    test "a good code authorizes every guarded change", %{
      user: user,
      secret: secret,
      token: token
    } do
      assert :ok = Recheck.recheck_with_totp(user, token, NimbleTOTP.verification_code(secret))

      for change <- [:change_email, :set_password, :add_factor, :remove_factor, :recovery_codes] do
        assert Recheck.authorized?(user, token, change)
      end
    end

    test "a wrong code authorizes nothing", %{user: user, secret: secret, token: token} do
      assert {:error, :invalid_code} =
               Recheck.recheck_with_totp(user, token, wrong_totp_code(secret))

      refute Recheck.authorized?(user, token, :remove_factor)
    end
  end

  describe "recheck_with_password/3" do
    setup do
      user = set_password(user_fixture())
      %{user: user, token: session_token(user)}
    end

    test "a fresh sign-in is not a re-check", %{user: user, token: token} do
      refute Recheck.authorized?(user, token, :change_email)
    end

    test "the right password authorizes every guarded change for this session", %{
      user: user,
      token: token
    } do
      assert :ok = Recheck.recheck_with_password(user, token, valid_user_password())
      assert Recheck.authorized?(user, token, :change_email)
      assert Recheck.authorized?(user, token, :set_password)

      refute Recheck.authorized?(user, session_token(user), :change_email)
    end

    test "a wrong password authorizes nothing", %{user: user, token: token} do
      assert {:error, :invalid_password} = Recheck.recheck_with_password(user, token, "nope")
      refute Recheck.authorized?(user, token, :change_email)
    end

    test "expires after five minutes", %{user: user, token: token} do
      :ok = Recheck.recheck_with_password(user, token, valid_user_password())

      Repo.update_all(AccountAuthorization,
        set: [expires_at: DateTime.add(Renga.Time.utc_now_ms(), -1, :second)]
      )

      refute Recheck.authorized?(user, token, :change_email)
    end

    test "another user's session authorizes nothing", %{user: user} do
      other = set_password(user_fixture())
      other_token = session_token(other)

      assert {:error, :no_session} =
               Recheck.recheck_with_password(user, other_token, valid_user_password())

      :ok = Recheck.recheck_with_password(other, other_token, valid_user_password())
      refute Recheck.authorized?(user, other_token, :change_email)
    end

    test "ends with the session", %{user: user, token: token} do
      :ok = Recheck.recheck_with_password(user, token, valid_user_password())
      Accounts.delete_user_session_token(token)

      refute Recheck.authorized?(user, token, :change_email)
      refute Repo.exists?(AccountAuthorization)
    end
  end

  describe "email bootstrap" do
    setup do
      user = user_fixture()
      %{user: user, token: session_token(user)}
    end

    test "a correct code authorizes only the first password or factor", %{
      user: user,
      token: token
    } do
      code = bootstrap_code(user, token)

      assert :ok = Recheck.verify_bootstrap_code(user, token, code)
      assert Recheck.authorized?(user, token, :set_password)
      assert Recheck.authorized?(user, token, :add_factor)
      refute Recheck.authorized?(user, token, :change_email)
      refute Recheck.authorized?(user, token, :remove_factor)
      refute Recheck.authorized?(user, token, :recovery_codes)
    end

    test "is bound to the session that asked for it", %{user: user, token: token} do
      code = bootstrap_code(user, token)
      other_token = session_token(user)

      assert {:error, :expired} = Recheck.verify_bootstrap_code(user, other_token, code)
      refute Recheck.authorized?(user, other_token, :set_password)
    end

    test "stops accepting codes after five wrong attempts", %{user: user, token: token} do
      code = bootstrap_code(user, token)

      for _ <- 1..5 do
        assert {:error, :invalid_code} = Recheck.verify_bootstrap_code(user, token, "WRONG-CODE0")
      end

      assert {:error, :too_many_attempts} = Recheck.verify_bootstrap_code(user, token, code)
    end

    test "a code is spent once", %{user: user, token: token} do
      code = bootstrap_code(user, token)
      :ok = Recheck.verify_bootstrap_code(user, token, code)

      assert {:error, :expired} = Recheck.verify_bootstrap_code(user, token, code)
    end

    test "expires after five minutes", %{user: user, token: token} do
      code = bootstrap_code(user, token)

      Repo.update_all(AccountChallenge,
        set: [expires_at: DateTime.add(Renga.Time.utc_now_ms(), -1, :second)]
      )

      assert {:error, :expired} = Recheck.verify_bootstrap_code(user, token, code)
    end

    test "is not offered once the account has a password", %{user: user, token: token} do
      user = set_password(user)
      token = if Accounts.get_user_by_session_token(token), do: token, else: session_token(user)

      assert {:error, :not_available} = Recheck.deliver_bootstrap_code(user, token)
    end

    test "a bootstrap ends once the first factor exists", %{user: user, token: token} do
      code = bootstrap_code(user, token)
      :ok = Recheck.verify_bootstrap_code(user, token, code)
      secret = MFA.new_totp_secret()
      {:ok, _codes} = MFA.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      refute Recheck.authorized?(user, token, :add_factor)
      refute Recheck.authorized?(user, token, :remove_factor)
    end

    test "a bootstrap does not survive setting the password", %{user: user, token: token} do
      code = bootstrap_code(user, token)
      :ok = Recheck.verify_bootstrap_code(user, token, code)

      user = set_password(user)
      refute Recheck.authorized?(user, token, :set_password)
    end
  end

  describe "re-check through a provider" do
    setup do
      fake = Renga.FakeOIDCProvider.new()
      provider = identity_provider_fixture(fake)
      user = user_fixture()

      {:ok, identity} =
        Accounts.link_identity(user, %{
          provider: provider,
          revision: Accounts.IdentityProviders.active_revision(provider),
          claims: %{"sub" => "subject-1"}
        })

      %{
        fake: fake,
        provider: provider,
        user: user,
        identity: identity,
        token: session_token(user)
      }
    end

    defp provider_result(provider, claims) do
      %{
        provider: provider,
        claims:
          Map.merge(
            %{"sub" => "subject-1", "auth_time" => System.system_time(:second)},
            claims
          )
      }
    end

    test "an account with only a linked provider re-checks there", %{
      user: user,
      identity: identity
    } do
      assert Recheck.methods(user) == [:provider]
      assert [%{id: id}] = Recheck.provider_identities(user)
      assert id == identity.id
    end

    test "a password or factor comes first", %{user: user} do
      assert Recheck.methods(set_password(user)) == [:password]
    end

    test "a fresh sign-in as the same subject records the re-check", %{
      user: user,
      provider: provider,
      identity: identity,
      token: token
    } do
      refute Recheck.authorized?(user, token, :link_identity)

      assert :ok =
               Recheck.recheck_with_provider(
                 user,
                 token,
                 identity.id,
                 provider_result(provider, %{})
               )

      assert Recheck.authorized?(user, token, :link_identity)
      assert Recheck.authorized?(user, token, :change_email)
    end

    test "another subject at the provider is refused", %{
      user: user,
      provider: provider,
      identity: identity,
      token: token
    } do
      assert {:error, :wrong_account} =
               Recheck.recheck_with_provider(
                 user,
                 token,
                 identity.id,
                 provider_result(provider, %{"sub" => "someone-else"})
               )

      refute Recheck.authorized?(user, token, :change_email)
    end

    test "another provider is refused", %{
      fake: fake,
      user: user,
      identity: identity,
      token: token
    } do
      other = identity_provider_fixture(fake)

      assert {:error, :wrong_account} =
               Recheck.recheck_with_provider(
                 user,
                 token,
                 identity.id,
                 provider_result(other, %{})
               )
    end

    test "auth_time must be present, an integer, recent, and not in the future", %{
      user: user,
      provider: provider,
      identity: identity,
      token: token
    } do
      now = System.system_time(:second)

      results = [
        Map.update!(provider_result(provider, %{}), :claims, &Map.delete(&1, "auth_time")),
        provider_result(provider, %{"auth_time" => "#{now}"}),
        provider_result(provider, %{"auth_time" => now * 1.0}),
        provider_result(provider, %{"auth_time" => now - 301}),
        provider_result(provider, %{"auth_time" => now + 3600})
      ]

      for result <- results do
        assert {:error, :stale_authentication} =
                 Recheck.recheck_with_provider(user, token, identity.id, result)
      end

      refute Recheck.authorized?(user, token, :change_email)
    end

    test "only when the provider is the account's re-check method", %{
      user: user,
      provider: provider,
      identity: identity
    } do
      user = set_password(user)
      token = session_token(user)

      assert {:error, :not_available} =
               Recheck.recheck_with_provider(
                 user,
                 token,
                 identity.id,
                 provider_result(provider, %{})
               )
    end

    test "an identity at a disabled provider cannot re-check", %{
      user: user,
      provider: provider,
      identity: identity,
      token: token
    } do
      Accounts.IdentityProviders.disable(provider, {:operator, "test"})
      assert Recheck.methods(user) == []

      assert {:error, :not_available} =
               Recheck.recheck_with_provider(
                 user,
                 token,
                 identity.id,
                 provider_result(provider, %{})
               )
    end

    test "another user's session records nothing", %{
      user: user,
      provider: provider,
      identity: identity
    } do
      other_token = session_token(user_fixture())

      assert {:error, :no_session} =
               Recheck.recheck_with_provider(
                 user,
                 other_token,
                 identity.id,
                 provider_result(provider, %{})
               )
    end

    test "the last identity the account re-checks with cannot be unlinked", %{
      fake: fake,
      user: user,
      provider: provider,
      identity: identity,
      token: token
    } do
      :ok =
        Recheck.recheck_with_provider(user, token, identity.id, provider_result(provider, %{}))

      assert {:error, :last_recheck_method} = Accounts.unlink_identity(user, token, identity.id)

      other = identity_provider_fixture(fake)

      {:ok, _} =
        Accounts.link_identity(user, %{
          provider: other,
          revision: Accounts.IdentityProviders.active_revision(other),
          claims: %{"sub" => "subject-2"}
        })

      assert {:ok, _} = Accounts.unlink_identity(user, token, identity.id)
    end
  end
end
