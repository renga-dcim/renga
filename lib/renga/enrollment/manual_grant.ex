defmodule Renga.Enrollment.ManualGrant do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "manual_grants" do
    field :public_id, :binary
    field :secret_hash, :string
    field :expires_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :enrollment_profile, Renga.Enrollment.EnrollmentProfile
    belongs_to :accepted_enrollment_binding, Renga.Enrollment.EnrollmentBinding
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:expires_at])
      |> validate_required([
        :organization_id,
        :enrollment_profile_id,
        :public_id,
        :secret_hash,
        :expires_at
      ])
      |> validate_length(:public_id, min: 16)
      |> validate_format(:secret_hash, ~r/^\$argon2/)
      |> check_constraint(:public_id, name: :manual_grants_valid)
end
