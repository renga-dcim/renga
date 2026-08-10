defmodule Renga.Enrollment.EnrollmentChallenge do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "enrollment_challenges" do
    field :installation_id, Ecto.UUID
    field :action, :string, default: "collector:enroll"
    field :public_key, :binary
    field :key_thumbprint, :binary
    field :nonce_hash, :binary
    field :status, :string, default: "open"
    field :expires_at, :utc_datetime_usec
    field :terminal_at, :utc_datetime_usec
    field :submission_digest, :binary
    field :safe_result, :map
    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :enrollment_profile, Renga.Enrollment.EnrollmentProfile
    belongs_to :enrollment_policy, Renga.Enrollment.EnrollmentPolicy
    belongs_to :verifier_configuration, Renga.Enrollment.VerifierConfiguration
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs),
    do:
      row
      |> cast(attrs, [:installation_id, :public_key, :key_thumbprint, :nonce_hash, :expires_at])
      |> validate_required([
        :organization_id,
        :enrollment_profile_id,
        :enrollment_policy_id,
        :verifier_configuration_id,
        :installation_id,
        :action,
        :public_key,
        :key_thumbprint,
        :nonce_hash,
        :expires_at
      ])
      |> validate_length(:public_key, is: 32)
      |> validate_length(:key_thumbprint, is: 32)
      |> validate_length(:nonce_hash, is: 32)
end
