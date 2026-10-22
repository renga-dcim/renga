defmodule Renga.Accounts.SecurityEvent do
  @moduledoc """
  An entry in an account's security log (RFD 19, "Security log and
  notices"): sign-ins, failed second steps, and credential changes. Rate
  limits for second-factor codes count the failures recorded here.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "account_security_events" do
    field :kind, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Renga.Accounts.User

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end
end
