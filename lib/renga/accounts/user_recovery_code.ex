defmodule Renga.Accounts.UserRecoveryCode do
  @moduledoc """
  One of an account's ten single-use recovery codes (RFD 19). Only a hash is
  stored; the codes are shown once, when the set is generated.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_recovery_codes" do
    field :code_hash, :binary, redact: true
    field :used_at, :utc_datetime_usec

    belongs_to :user, Renga.Accounts.User

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end
end
