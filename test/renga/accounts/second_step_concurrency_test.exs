defmodule Renga.Accounts.SecondStepConcurrencyTest do
  @moduledoc """
  Finishing a pending sign-in and changing the password serialize on the
  account's row: whichever commits first, no session issued from the
  pending sign-in outlives the password change.
  """
  use ExUnit.Case, async: false

  import Renga.AccountsFixtures
  import Renga.MutationRace, only: [race: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Repo

  import Ecto.Query, only: [where: 2]

  @new_password %{password: "a brand new password", password_confirmation: "a brand new password"}

  test "a password change after the session is issued ends it" do
    with_pending_sign_in(fn user, pending ->
      assert {{:ok, session}, {:ok, _}} =
               race(
                 fn -> Accounts.finish_pending_second_step(user, pending, nil, :totp) end,
                 fn -> Accounts.update_user_password(user, @new_password) end
               )

      refute Accounts.get_user_by_session_token(session)
    end)
  end

  test "a password change first leaves nothing to finish" do
    with_pending_sign_in(fn user, pending ->
      assert {{:ok, _}, :error} =
               race(
                 fn -> Accounts.update_user_password(user, @new_password) end,
                 fn -> Accounts.finish_pending_second_step(user, pending, nil, :totp) end
               )

      assert Repo.aggregate(
               where(Accounts.UserToken, user_id: ^user.id, context: "session"),
               :count
             ) == 0
    end)
  end

  defp with_pending_sign_in(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    user = user_fixture() |> set_password()
    pending = Accounts.create_pending_second_step(user)

    try do
      fun.(user, pending)
    after
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end
end
