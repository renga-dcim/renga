defmodule Renga.Accounts.PasskeyConcurrencyTest do
  @moduledoc """
  Passkeys are added and removed under the account lock that every
  second-factor change takes (`Renga.Accounts.MFA`), so a recovery grant
  adds one passkey and recovery codes never outlive the last factor.
  """
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.MutationRace, only: [race: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Accounts.MFA
  alias Renga.FakeAuthenticator
  alias Renga.Repo

  test "a recovery grant adds one passkey, even to concurrent requests" do
    with_user(fn user ->
      {_secret, [code | _]} = totp_fixture(user)
      :ok = MFA.spend_recovery_code(user, code)
      token = Accounts.generate_user_session_token(user)
      :ok = Accounts.start_recovery(user, token)

      [first, second] =
        for _ <- 1..2,
            do:
              FakeAuthenticator.register(
                FakeAuthenticator.new(),
                Accounts.passkey_registration_options(user)
              )

      assert {{:ok, _passkey, nil}, {:error, :recheck_required}} =
               race(fn -> Accounts.add_passkey(user, token, first, "One") end, fn ->
                 Accounts.add_passkey(user, token, second, "Two")
               end)

      assert length(Accounts.list_passkeys(user)) == 1
      assert MFA.recovery_codes_left(user) == 9
    end)
  end

  test "codes are never created after the last passkey is removed" do
    with_user(fn user ->
      token = Accounts.generate_user_session_token(user)
      :ok = Accounts.recheck_with_password(user, token, valid_user_password())

      response =
        FakeAuthenticator.register(
          FakeAuthenticator.new(),
          Accounts.passkey_registration_options(user)
        )

      {:ok, passkey, codes} = Accounts.add_passkey(user, token, response, "Only")
      assert length(codes) == 10

      assert {{:ok, _}, {:error, :no_mfa}} =
               race(fn -> Accounts.remove_passkey(user, token, passkey.id) end, fn ->
                 MFA.regenerate_recovery_codes(user)
               end)

      assert MFA.recovery_codes_left(user) == 0
    end)
  end

  defp with_user(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture() |> set_password()

    try do
      fun.(user)
    after
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end
end
