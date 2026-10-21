defmodule Renga.Accounts.RecoveryReplacementTest do
  @moduledoc """
  A recovery authorization (RFD 19, "Recovery") adds exactly one
  replacement factor. The grant is spent in the transaction that saves the
  replacement, so a second replacement, even a concurrent one, is refused.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.MutationRace, only: [race: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Accounts.MFA
  alias Renga.Accounts.UserTOTP
  alias Renga.Repo

  test "a replacement keeps the remaining codes and spends the grant" do
    with_recovering_user(fn user, token ->
      secret = MFA.new_totp_secret()
      wrong = wrong_totp_code(secret)

      # A wrong code leaves both the old app and the grant in place.
      assert {:error, :invalid_code} = Accounts.add_totp(user, token, secret, wrong)
      assert Accounts.recovering?(user, token)

      assert {:ok, nil} = Accounts.add_totp(user, token, secret, code(secret))
      assert MFA.recovery_codes_left(user) == 9
      refute Accounts.recovering?(user, token)
      refute Accounts.authorized_account_change?(user, token, :recovery_codes)

      another = MFA.new_totp_secret()
      assert {:error, _} = Accounts.add_totp(user, token, another, code(another))
    end)
  end

  test "a passkey with a key Renga did not offer leaves the grant unspent" do
    with_recovering_user(fn user, token ->
      response =
        Renga.FakeAuthenticator.register(
          Renga.FakeAuthenticator.new(alg: -8),
          Accounts.passkey_registration_options(user)
        )

      assert {:error, :invalid_response} = Accounts.add_passkey(user, token, response, "Key")
      assert Accounts.recovering?(user, token)
      assert Accounts.list_passkeys(user) == []
    end)
  end

  test "two concurrent replacements use the grant once" do
    with_recovering_user(fn user, token ->
      first = MFA.new_totp_secret()
      second = MFA.new_totp_secret()

      assert {{:ok, nil}, {:error, :recheck_required}} =
               race(fn -> Accounts.add_totp(user, token, first, code(first)) end, fn ->
                 Accounts.add_totp(user, token, second, code(second))
               end)

      # The first replacement is the one kept.
      assert :ok = MFA.verify_totp(user, code(first, 1))
      assert Repo.aggregate(where(UserTOTP, user_id: ^user.id), :count) == 1
    end)
  end

  defp code(secret, steps \\ 0),
    do: NimbleTOTP.verification_code(secret, time: System.os_time(:second) + steps * 30)

  defp with_recovering_user(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture()
    {_secret, [recovery_code | _]} = totp_fixture(user)
    :ok = MFA.spend_recovery_code(user, recovery_code)
    token = Accounts.generate_user_session_token(user)
    :ok = Accounts.start_recovery(user, token)

    try do
      fun.(user, token)
    after
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end
end
