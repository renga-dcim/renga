defmodule Renga.Enrollment.AgentCredential do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_credentials" do
    field :credential_id, :binary
    field :public_key, :binary
    field :key_thumbprint, :binary
    field :status, :string, default: "active"
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :source, Renga.Inventory.Source
    belongs_to :agent, Renga.Inventory.Agent
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:expires_at])
      |> validate_required([
        :organization_id,
        :source_id,
        :agent_id,
        :credential_id,
        :public_key,
        :key_thumbprint,
        :expires_at
      ])
      |> validate_length(:credential_id, min: 32, count: :bytes)
      |> validate_length(:public_key, is: 32, count: :bytes)
      |> validate_length(:key_thumbprint, is: 32, count: :bytes)
      |> validate_inclusion(:status, ~w(active quarantined revoked expired))
end
