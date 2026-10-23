defmodule Renga.Accounts.SessionConfirmationTest do
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures

  alias Renga.Accounts
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
end
