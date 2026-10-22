defmodule Renga.Accounts.LocalSignInOverride do
  @moduledoc """
  A time-limited exception that lets existing local credentials sign in
  while the environment disables them (RFD 15, `recover-local`). Only the
  operator's release command creates or revokes one, and it never opens
  registration.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "local_sign_in_overrides" do
    field :expires_at, :utc_datetime_usec
    field :created_by, :string
    field :revoked_at, :utc_datetime_usec
    field :revoked_by, :string

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end
end
