defmodule Renga.Accounts.SessionConfirmationTest do
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures

  alias Renga.Accounts
  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.UserToken

  test "an audit failure rolls back session MFA confirmation" do
    user = user_fixture()
    {secret, _recovery_codes} = totp_fixture(user)
    token = Accounts.generate_user_session_token(user)

    Repo.query!("""
    ALTER TABLE account_security_events
    ADD CONSTRAINT reject_session_confirmation
    CHECK (kind <> 'second_factor_confirmed')
    """)

    assert_raise Ecto.ConstraintError, fn ->
      Accounts.confirm_session_second_factor(
        user,
        token,
        NimbleTOTP.verification_code(secret)
      )
    end

    assert Repo.get_by!(UserToken, token: token).second_factor_at == nil
  end

  test "confirmation cannot elevate another user's session" do
    user = user_fixture()
    {secret, _recovery_codes} = totp_fixture(user)
    other_session = Accounts.generate_user_session_token(user_fixture())

    assert {:error, :no_session} =
             Accounts.confirm_session_second_factor(
               user,
               other_session,
               NimbleTOTP.verification_code(secret)
             )

    assert Repo.get_by!(UserToken, token: other_session).second_factor_at == nil

    refute Repo.exists?(
             from event in SecurityEvent,
               where: event.user_id == ^user.id and event.kind == "second_factor_confirmed"
           )
  end
end
