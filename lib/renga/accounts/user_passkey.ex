defmodule Renga.Accounts.UserPasskey do
  @moduledoc """
  A WebAuthn credential on an account (RFD 19, "Credentials"): its ID,
  public key, signature counter, transports, and backup flags, with the name
  the person gave it and when it was last used.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_passkeys" do
    field :credential_id, :binary
    field :public_key, :binary, redact: true
    field :sign_count, :integer, default: 0
    field :transports, {:array, :string}, default: []
    field :backup_eligible, :boolean, default: false
    field :backed_up, :boolean, default: false
    field :name, :string
    field :last_used_at, :utc_datetime_usec

    belongs_to :user, Renga.Accounts.User

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []}
    )
  end

  def name_changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
  end
end
