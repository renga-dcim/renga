defmodule Renga.Enrollment.EnrollmentProfile do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  schema "enrollment_profiles" do
    field :selector, :string
    field :name, :string
    field :enabled, :boolean, default: true
    field :disabled_at, :utc_datetime_usec
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :enrollment_policy, Renga.Enrollment.EnrollmentPolicy
    belongs_to :verifier_configuration, Renga.Enrollment.VerifierConfiguration
    timestamps()
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:selector, :name, :enrollment_policy_id, :verifier_configuration_id])
      |> validate_required([
        :organization_id,
        :selector,
        :name,
        :enrollment_policy_id,
        :verifier_configuration_id
      ])
      |> validate_length(:selector, max: 255)
      |> unique_constraint([:organization_id, :selector])
      |> foreign_key_constraint(:enrollment_policy_id,
        name: :enrollment_profiles_enrollment_policy_id_tenant_fkey
      )
      |> foreign_key_constraint(:verifier_configuration_id,
        name: :enrollment_profiles_verifier_configuration_id_tenant_fkey
      )

  def disable_changeset(row, now),
    do:
      row
      |> change(enabled: false, disabled_at: now)
      |> check_constraint(:enabled, name: :enrollment_profiles_enabled_state)
end
