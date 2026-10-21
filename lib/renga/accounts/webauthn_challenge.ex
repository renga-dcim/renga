defmodule Renga.Accounts.WebAuthnChallenge do
  @moduledoc """
  A challenge handed to the browser for one passkey ceremony. Verification
  deletes it, so a captured response cannot be replayed, and a challenge
  issued for one user or purpose cannot complete another.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webauthn_challenges" do
    field :bytes, :binary
    field :purpose, :string
    field :expires_at, :utc_datetime_usec

    belongs_to :user, Renga.Accounts.User

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end
end
