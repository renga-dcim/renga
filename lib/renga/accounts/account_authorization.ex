defmodule Renga.Accounts.AccountAuthorization do
  @moduledoc """
  Short-lived evidence bound to one browser session (RFD 19).

  * `recheck` - the person passed the account re-check and may make
    account-takeover changes until it expires.
  * `bootstrap` - an account with no password and no second factor proved
    control of its email and may set its first password or add its first
    factor, and nothing else.
  * `recovery` - the person signed in with a recovery code and may add one
    replacement factor.

  The row references the session token, so signing out, rotating the session,
  or expiring every token on a password change also ends the authorization.
  """

  use Ecto.Schema

  @purposes ~w(recheck bootstrap recovery)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "account_authorizations" do
    field :purpose, :string
    field :expires_at, :utc_datetime_usec

    belongs_to :user, Renga.Accounts.User
    belongs_to :session_token, Renga.Accounts.UserToken

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end

  def purposes, do: @purposes
end
