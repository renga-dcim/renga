defmodule Renga.Enrollment.EnrollmentPolicy do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  schema "enrollment_policies" do
    field :name, :string
    field :version, :integer
    field :document, :map
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :created_by_membership, Renga.Accounts.OrganizationMembership
    timestamps(updated_at: false)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:name, :version, :document])
      |> validate_required([
        :organization_id,
        :created_by_membership_id,
        :name,
        :version,
        :document
      ])
      |> validate_length(:name, max: 255)
      |> validate_number(:version, greater_than: 0)
      |> check_constraint(:document, name: :enrollment_policies_document_size)
      |> unique_constraint([:organization_id, :name, :version])
end
