defmodule Renga.Accounts.SignInPolicyConcurrencyTest do
  @moduledoc """
  A sign-in that a local recovery override allows holds the override until
  it commits, so revoking the override waits for it: every session is
  issued either before the revocation or not at all (RFD 15).
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.MutationRace, only: [race: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Accounts.LocalSignInOverride
  alias Renga.Accounts.SignInPolicy
  alias Renga.Repo

  test "revoking an override waits for a sign-in it allowed" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Application.put_env(:renga, :local_sign_in, :disabled)
    user = user_fixture()
    {:ok, override} = SignInPolicy.recover_local(30, "jane")

    try do
      assert {{:ok, token}, {:ok, 1}} =
               race(
                 fn ->
                   Accounts.create_signed_in_session(user, Ecto.UUID.generate(), "password")
                 end,
                 fn -> SignInPolicy.revoke_overrides("jane") end
               )

      assert Accounts.get_user_by_session_token(token)
      assert :error = Accounts.create_signed_in_session(user, Ecto.UUID.generate(), "password")
    after
      Application.delete_env(:renga, :local_sign_in)
      Repo.delete_all(where(LocalSignInOverride, id: ^override.id))
      Repo.delete!(user)
      Sandbox.checkin(Repo)
    end
  end
end
