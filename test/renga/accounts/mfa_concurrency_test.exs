defmodule Renga.Accounts.MFAConcurrencyTest do
  @moduledoc """
  Second-factor checks and changes serialize on the account's row
  (`Renga.Accounts.MFA`). Each race holds one call's transaction open on its
  own connection, shows a competing call waits for it, and then that the
  competitor saw what the first one committed.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.MutationRace, only: [race: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Accounts.MFA
  alias Renga.Accounts.Passkeys
  alias Renga.Accounts.SecurityEvent
  alias Renga.Repo

  test "a failure committed by one check counts against the next" do
    with_totp_user(fn user, secret ->
      record_failures(user, 9)
      wrong = wrong_totp_code(secret)

      assert {{:error, :invalid_code}, {:error, :rate_limited}} =
               race(fn -> MFA.verify_totp(user, wrong) end, fn ->
                 MFA.verify_totp(user, wrong)
               end)
    end)

    with_totp_user(fn user, _secret ->
      record_failures(user, 9)

      assert {{:error, :invalid_code}, {:error, :rate_limited}} =
               race(fn -> MFA.spend_recovery_code(user, "nope-nope-nope-nope") end, fn ->
                 MFA.spend_recovery_code(user, "nope-nope-nope-nope")
               end)
    end)
  end

  test "two new recovery code sets never both stay valid" do
    with_totp_user(fn user, _secret ->
      assert {{:ok, first}, {:ok, second}} =
               race(fn -> MFA.regenerate_recovery_codes(user) end, fn ->
                 MFA.regenerate_recovery_codes(user)
               end)

      assert MFA.recovery_codes_left(user) == 10
      assert {:error, :invalid_code} = MFA.spend_recovery_code(user, hd(first))
      assert :ok = MFA.spend_recovery_code(user, hd(second))
    end)
  end

  test "codes are never created after the last factor is removed" do
    with_totp_user(fn user, _secret ->
      assert {{:ok, _user}, {:error, :no_mfa}} =
               race(fn -> MFA.disable_totp(user) end, fn ->
                 MFA.regenerate_recovery_codes(user)
               end)

      assert MFA.recovery_codes_left(user) == 0
    end)
  end

  test "one authenticator code is accepted once across concurrent checks" do
    with_totp_user(fn user, secret ->
      code = NimbleTOTP.verification_code(secret)

      assert {:ok, {:error, :invalid_code}} =
               race(fn -> MFA.verify_totp(user, code) end, fn ->
                 MFA.verify_totp(user, code)
               end)
    end)
  end

  test "resealing every secret tolerates one resealed by a sign-in meanwhile" do
    with_totp_user(fn user, secret ->
      previous = Application.get_env(:renga, Renga.Vault)
      new_key = "next:" <> Base.encode64(:crypto.strong_rand_bytes(32))
      Application.put_env(:renga, Renga.Vault, keys: new_key <> "," <> previous[:keys])

      try do
        assert {:ok, {:ok, 0}} =
                 race(fn -> MFA.verify_totp(user, NimbleTOTP.verification_code(secret)) end, fn ->
                   MFA.reencrypt_totp_secrets()
                 end)
      after
        Application.put_env(:renga, Renga.Vault, previous)
      end
    end)
  end

  test "removing the password and the last passkey cannot both succeed" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = set_password(user_fixture())

    try do
      authenticator = Renga.FakeAuthenticator.new()

      response =
        Renga.FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))

      {:ok, passkey} = Passkeys.register(user, response, "Laptop")
      token = Accounts.generate_user_session_token(user)
      options = Accounts.passkey_options(user, "recheck")

      :ok =
        Accounts.recheck_with_passkey(
          user,
          token,
          Renga.FakeAuthenticator.assert(authenticator, options)
        )

      # The password removal must wait to see the passkey gone.
      assert {{:ok, _passkey}, {:error, :no_passkey}} =
               race(fn -> Accounts.remove_passkey(user, token, passkey.id) end, fn ->
                 Accounts.remove_user_password(user, token)
               end)

      assert Repo.get!(Accounts.User, user.id).hashed_password
    after
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end

  test "a bootstrap session is not issued once a factor is added meanwhile" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture()

    try do
      authenticator = Renga.FakeAuthenticator.new()

      response =
        Renga.FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))

      assert {{:ok, _added}, :error} =
               race(
                 fn ->
                   MFA.add_factor(user, fn -> Passkeys.register(user, response, "Key") end, fn ->
                     true
                   end)
                 end,
                 fn -> Accounts.create_bootstrap_session(user, Ecto.UUID.generate()) end
               )

      refute Repo.exists?(
               from t in Accounts.UserToken,
                 where: t.user_id == ^user.id and t.context == "session"
             )
    after
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end

  defp with_totp_user(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture()
    secret = MFA.new_totp_secret()

    # Enrolment commits outside the sandbox, so it sits inside the `try`
    # for its user row to be deleted even when the fixture raises.
    try do
      # Leaves the current step unspent.
      totp_fixture(user, secret: secret)
      fun.(user, secret)
    after
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end

  defp record_failures(user, count) do
    for _ <- 1..count,
        do: Repo.insert!(%SecurityEvent{user_id: user.id, kind: "totp_failed"})

    assert Repo.aggregate(where(SecurityEvent, user_id: ^user.id), :count) >= count
  end
end
