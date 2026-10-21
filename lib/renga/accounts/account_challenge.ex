defmodule Renga.Accounts.AccountChallenge do
  @moduledoc """
  An emailed code that proves control of an account's current email address
  for RFD 19's first-password or first-factor bootstrap.

  Only the code's hash is stored, the challenge belongs to the session that
  requested it, and it accepts a handful of attempts before it must be sent
  again.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "account_challenges" do
    field :purpose, :string
    field :code_hash, :binary, redact: true
    field :sent_to, :string
    field :attempts, :integer, default: 0
    field :expires_at, :utc_datetime_usec

    belongs_to :user, Renga.Accounts.User
    belongs_to :session_token, Renga.Accounts.UserToken

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end
end
