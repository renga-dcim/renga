defmodule Renga.Inventory.IntakeApiKey do
  @moduledoc """
  Organization credential restricted to collector intake authentication.

  Plaintext key material is returned only when a key is created. This schema
  retains only its cryptographic hash so issued keys cannot be reconstructed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(active revoked)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "intake_api_keys" do
    field :name, :string
    field :status, :string, default: "active"
    field :token_hash, :binary

    belongs_to :organization, Organization

    timestamps()
  end

  def create_changeset(intake_api_key, attrs, token_hash) when is_binary(token_hash) do
    intake_api_key
    |> cast(attrs, [:name])
    |> put_change(:token_hash, token_hash)
    |> update_change(:name, &String.trim/1)
    |> validate_required([:organization_id, :name, :status, :token_hash])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:organization)
    |> unique_constraint(:token_hash)
  end

  def revoke_changeset(intake_api_key) do
    change(intake_api_key, status: "revoked")
  end
end
