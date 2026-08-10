defmodule Renga.Enrollment.EnrollmentBinding do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enrollment_bindings" do
    field :installation_id, Ecto.UUID
    field :public_key, :binary
    field :key_thumbprint, :binary
    field :assignments, :map, default: %{}
    field :grants, {:array, :string}, default: []
    field :status, :string, default: "active"
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :enrollment_identity, Renga.Enrollment.EnrollmentIdentity
    belongs_to :source, Renga.Inventory.Source
    belongs_to :agent, Renga.Inventory.Agent
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:assignments, :grants, :status])
      |> validate_required([
        :organization_id,
        :enrollment_identity_id,
        :source_id,
        :agent_id,
        :installation_id,
        :public_key,
        :key_thumbprint,
        :status
      ])
      |> validate_inclusion(:status, ~w(active disabled replaced))
end
