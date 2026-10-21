defmodule Renga.Accounts.UserTOTP do
  @moduledoc """
  An account's authenticator app (RFD 19): an RFC 6238 secret with 30-second
  steps and six digits, and the last step Renga accepted so no code works
  twice.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_totps" do
    field :secret, :binary, redact: true
    field :last_used_step, :integer

    belongs_to :user, Renga.Accounts.User

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []}
    )
  end
end
