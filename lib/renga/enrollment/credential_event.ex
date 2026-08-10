defmodule Renga.Enrollment.CredentialEvent do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credential_events" do
    field :kind, :string
    field :occurred_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :agent_credential, Renga.Enrollment.AgentCredential
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:kind, :occurred_at, :metadata])
      |> validate_required([:organization_id, :agent_credential_id, :kind, :occurred_at])
end
