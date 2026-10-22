defmodule Renga.Scim.Token do
  @moduledoc """
  A bearer token a SCIM connection's provider authenticates with (RFD 16,
  "Connections"). Like intake keys, the value is shown once when it is
  issued and only its hash is kept. A connection holds at most two unrevoked
  tokens, so one can be rotated without downtime.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "scim_tokens" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :organization_id, :binary_id

    belongs_to :connection, Renga.Scim.Connection
    belongs_to :created_by_user, Renga.Accounts.User
    belongs_to :revoked_by_user, Renga.Accounts.User

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end

  def create_changeset(token, attrs, token_hash) when is_binary(token_hash) do
    token
    |> cast(attrs, [:name])
    |> put_change(:token_hash, token_hash)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:organization_id, :connection_id, :name, :token_hash])
    |> validate_length(:name, max: 80)
    |> unique_constraint(:token_hash)
  end
end
